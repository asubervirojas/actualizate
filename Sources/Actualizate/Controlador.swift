import AppKit
import Foundation
import UserNotifications

enum Modo {
    case revisar, instalar
    /// Busca apps instaladas a mano que Homebrew puede adoptar
    case adoptables
    /// Instala las copias de Homebrew y retira originales duplicados tras verificarlas
    case adoptar

    var nombreRegistro: String {
        switch self {
        case .revisar: "revisar"
        case .instalar: "instalar"
        case .adoptables: "adoptables"
        case .adoptar: "adoptar"
        }
    }
}

struct Resultado {
    let modo: Modo
    let codigo: Int32
    let duracion: TimeInterval
    let cancelado: Bool
    let errores: [String]
    let pendientes: Int
    let archivo: URL?
}

/// Corre el motor `actualizar` en una terminal propia y traduce sus marcas al estado de la ventana.
@MainActor
final class Controlador: ObservableObject {
    static let compartido = Controlador()

    @Published var etapas: [EtapaEstado] = DefinicionEtapa.todas.map { EtapaEstado(def: $0) }
    @Published var elegidos: Set<String> = []
    @Published var etapasElegidas: Set<String> = []
    // Pausa manual (Ajustes); activa por defecto y un fallo ya no la pausa sola. Clave nueva: la vieja,
    // microsoftPausado, la escribia la pausa automatica y no refleja lo que eligio el usuario
    @Published var microsoftPausado = UserDefaults.standard.object(forKey: "microsoftPausaManual") as? Bool ?? false {
        didSet {
            defaults.set(microsoftPausado, forKey: "microsoftPausaManual")
            if !corriendo { reflejarPausaMicrosoft() }
        }
    }
    @Published private(set) var modo: Modo?
    @Published private(set) var etapaActual: String?
    @Published var pidiendoClave = false
    @Published private(set) var textoClave = ""
    @Published private(set) var claveIncorrecta = false
    @Published private(set) var esperandoAutorizacion = false
    @Published private(set) var lineaParcial = ""
    /// Ultima linea con texto de la salida, para mostrar el avance sin abrir el registro
    @Published private(set) var ultimaLinea = ""
    /// item.id -> avance de cada app que se esta actualizando (la barra de su fila)
    @Published private(set) var avances: [String: Avance] = [:]
    @Published private(set) var ultimaRevision: Date?
    @Published var resultado: Resultado?

    // Adoptar apps
    @Published var mostrandoAdoptar = false
    @Published private(set) var adoptables: [Adoptable] = []
    @Published var adoptablesElegidos: Set<String> = []
    @Published private(set) var adoptablesBuscados = false
    @Published private(set) var errorInventario: String?
    /// token -> se adopto bien
    @Published private(set) var resultadosAdopcion: [String: Bool] = [:]
    private var adoptablesEnCurso: [Adoptable] = []
    /// Que corrio por ultimo: la hoja de adopcion solo busca sola despues de una revision o actualizacion
    @Published private(set) var ultimoModoTerminado: Modo?

    let registro = Registro()

    private var proceso: ProcesoPTY?
    private var terminal = Terminal()
    private var inicio = Date()
    private var cancelado = false
    private var silencioso = false
    private var respondiClave = false
    private var itemsEnCurso: [String: [Item]] = [:]
    private var notasEnCurso: [String: [String]] = [:]
    private var instalandoItems: Set<String> = []
    private var pendientesAntes: Set<String> = []
    /// Etapas que corrieron en esta ejecucion: los errores de antes no se le culpan a esta
    private var etapasCorridas: Set<String> = []
    private var falloAutorizacion = false
    /// App que brew esta instalando: las lineas sin nombre que siguen ("Pouring", "Moving App") son suyas
    private var itemTrabajando: String?
    private var temporizador: Timer?

    /// Abre la ventana principal (la registra la vista): sudo puede pedir contrasena con la ventana cerrada
    var abrirPrincipal: (() -> Void)? {
        didSet { presentarAppsPendientes() }
    }
    private var aperturaAppsPendiente = false

    private let defaults = UserDefaults.standard

    init() {
        ultimaRevision = defaults.object(forKey: "ultimaRevision") as? Date
        reflejarPausaMicrosoft()
        temporizador = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated { Controlador.compartido.revisarSiToca() }
        }
    }

    private func reflejarPausaMicrosoft() {
        guard let i = indice("microsoft") else { return }
        etapas[i].items = []
        etapas[i].estado = microsoftPausado ? .pausada : .sinRevisar
        etapas[i].notas = microsoftPausado ? ["Microsoft AutoUpdate está en pausa. Puedes reactivarlo en Ajustes. Las apps gestionadas por Homebrew siguen revisándose por esa fuente."] : []
        etapas[i].mensaje = nil
        etapasElegidas.remove("microsoft")
        elegidos = elegidos.filter { !$0.hasPrefix("microsoft/") }
        actualizarInsignia()
    }

    var corriendo: Bool { modo != nil }

    var totalPendientes: Int { etapas.reduce(0) { $0 + $1.items.count } }

    /// Elementos que se van a instalar con "Actualizar seleccionadas"
    var totalElegidos: Int {
        etapas.reduce(0) { suma, e in
            if e.id == "microsoft" && microsoftPausado { return suma }
            switch e.def.seleccion {
            case .porItem: return suma + e.items.filter { elegidos.contains($0.id) }.count
            case .porEtapa: return suma + (etapasElegidas.contains(e.id) ? max(e.items.count, 1) : 0)
            case .manual: return suma
            }
        }
    }

    var rutaMotor: String {
        if let ruta = ProcessInfo.processInfo.environment["ACTUALIZAR_MOTOR"], !ruta.isEmpty { return ruta }
        return Bundle.main.url(forResource: "actualizar", withExtension: nil)?.path ?? ""
    }

    // Lleva el nombre del comando actualizar, no el de la app: los registros anteriores siguen ahi
    static var carpetaRegistros: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Actualizar", isDirectory: true)
    }

    private var betas: Bool { defaults.bool(forKey: "betas") }

    // MARK: Acciones

    func revisar(silencioso: Bool = false) {
        guard !corriendo else { return }
        pendientesAntes = Set(etapas.flatMap { $0.items.map(\.id) })
        var args = ["revisar"]
        if betas { args.append("--betas") }
        lanzar(.revisar, args, silencioso: silencioso)
    }

    func instalarSeleccion() {
        guard !corriendo else { return }
        var args = ["instalar"]
        var lista: [String] = []
        instalandoItems = []
        for e in etapas {
            if e.id == "microsoft" && microsoftPausado { continue }
            switch e.def.seleccion {
            case .porItem:
                let elegidas = e.items.filter { elegidos.contains($0.id) }
                guard !elegidas.isEmpty else { continue }
                lista.append(e.id)
                args += ["--\(e.id)", elegidas.map(\.clave).joined(separator: ",")]
                instalandoItems.formUnion(elegidas.map(\.id))
            case .porEtapa:
                guard etapasElegidas.contains(e.id) else { continue }
                lista.append(e.id)
                instalandoItems.formUnion(e.items.map(\.id))
            case .manual:
                continue
            }
        }
        guard !lista.isEmpty else { return }
        args += ["--etapas", lista.joined(separator: ",")]
        if betas { args.append("--betas") }
        lanzar(.instalar, args)
    }

    /// Lo de siempre: revisa e instala todo en orden
    func instalarTodo() {
        guard !corriendo else { return }
        instalandoItems = Set(etapas.flatMap { $0.items.map(\.id) })
        var args = ["instalar"]
        if betas { args.append("--betas") }
        lanzar(.instalar, args)
    }

    func cancelar() {
        guard let proceso, corriendo else { return }
        cancelado = true
        proceso.interrumpir()
        // Si en 8 s no salio por las buenas, se corta la sesion
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.corriendo, self.cancelado else { return }
                self.proceso?.terminar()
            }
        }
    }

    func terminarAlSalir() {
        proceso?.terminar()
    }

    func enviar(_ texto: String) {
        proceso?.escribir(texto)
    }

    func enviarClave(_ clave: String) {
        respondiClave = true
        pidiendoClave = false
        claveIncorrecta = false
        proceso?.escribir(clave + "\n")
    }

    func cancelarClave() {
        pidiendoClave = false
        cancelar()
    }

    func elegirTodos(_ etapa: EtapaEstado, _ si: Bool) {
        for item in etapa.items {
            if si { elegidos.insert(item.id) } else { elegidos.remove(item.id) }
        }
    }

    func revisarSiToca() {
        let horas = defaults.object(forKey: "intervaloHoras") as? Int ?? 12
        guard horas > 0, !corriendo, !mostrandoAdoptar else { return }
        if let ultima = ultimaRevision, Date().timeIntervalSince(ultima) < Double(horas) * 3600 { return }
        revisar(silencioso: true)
    }

    // MARK: Adoptar apps

    /// Las marcadas que se pueden adoptar y que no se adoptaron ya
    private var adoptablesParaAdoptar: [Adoptable] {
        adoptables.filter { $0.estado.adoptable && adoptablesElegidos.contains($0.id) && resultadosAdopcion[$0.token] != true }
    }

    var totalAdoptablesElegidos: Int { adoptablesParaAdoptar.count }

    func buscarAdoptables(conservarResultados: Bool = false) {
        guard !corriendo else { return }
        adoptablesEnCurso = []
        errorInventario = nil
        if !conservarResultados { resultadosAdopcion = [:] }
        lanzar(.adoptables, ["adoptables"])
    }

    func adoptar() {
        guard !corriendo, errorInventario == nil else { return }
        let tokens = Array(Set(adoptablesParaAdoptar.map(\.token))).sorted()
        guard !tokens.isEmpty else { return }
        for token in tokens { resultadosAdopcion[token] = nil }
        lanzar(.adoptar, ["adoptar", "--casks", tokens.joined(separator: ",")])
    }

    /// Abre la hoja de adopcion (desde la barra de menus o el menu de la app) y busca si hace falta
    func abrirAdoptar() {
        // Con una revision o actualizacion en curso la hoja taparia su avance y la contrasena
        guard modo != .revisar && modo != .instalar else { return }
        aperturaAppsPendiente = true
        mostrandoAdoptar = true
        presentarAppsPendientes()
        if !adoptablesBuscados && !corriendo { buscarAdoptables() }
    }

    /// El arranque puede pedir la hoja antes de que SwiftUI registre cómo abrir la ventana.
    private func presentarAppsPendientes() {
        guard aperturaAppsPendiente, let abrirPrincipal else { return }
        aperturaAppsPendiente = false
        DispatchQueue.main.async { abrirPrincipal() }
    }

    var puedeAdoptar: Bool { modo != .revisar && modo != .instalar }

    // MARK: Proceso

    private func lanzar(_ nuevoModo: Modo, _ args: [String], silencioso: Bool = false) {
        let motor = rutaMotor
        guard FileManager.default.isExecutableFile(atPath: motor) else {
            let mensaje = "No se encontró el motor actualizar en \(motor)"
            registro.agregar([mensaje])
            if nuevoModo == .adoptables { errorInventario = mensaje }
            return
        }
        modo = nuevoModo
        self.silencioso = silencioso
        cancelado = false
        // Adoptar no toca el resultado de la ultima revision o actualizacion
        if nuevoModo == .revisar || nuevoModo == .instalar { resultado = nil }
        respondiClave = false
        claveIncorrecta = false
        esperandoAutorizacion = false
        etapaActual = nil
        lineaParcial = ""
        ultimaLinea = ""
        itemsEnCurso = [:]
        notasEnCurso = [:]
        etapasCorridas = []
        falloAutorizacion = false
        itemTrabajando = nil
        // Cada app que se va a instalar arranca con su barra vacia; los avisos manuales no se instalan
        avances = [:]
        if nuevoModo == .instalar {
            for e in etapas where e.def.seleccion != .manual {
                for item in e.items where instalandoItems.contains(item.id) { avances[item.id] = Avance() }
            }
        }
        terminal = Terminal()
        inicio = Date()
        registro.limpiar()
        registro.agregar(["$ actualizar \(args.joined(separator: " "))", ""])

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var entorno = ProcessInfo.processInfo.environment
        entorno["ACTUALIZAR_APP"] = "1"
        entorno["ACTUALIZAR_MICROSOFT_PAUSADO"] = microsoftPausado ? "1" : "0"
        entorno["TERM"] = "xterm-256color"
        entorno["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if entorno["LANG"] == nil { entorno["LANG"] = "en_US.UTF-8" }
        entorno["ACTUALIZAR_MOTOR"] = nil

        let p = ProcesoPTY()
        p.alRecibir = { [weak self] datos in
            MainActor.assumeIsolated { self?.recibir(datos) }
        }
        p.alTerminar = { [weak self] codigo in
            MainActor.assumeIsolated { self?.terminado(codigo) }
        }
        do {
            try p.iniciar(ejecutable: "/bin/zsh", argumentos: ["-f", motor] + args, entorno: entorno, directorio: home)
            proceso = p
        } catch {
            registro.agregar([error.localizedDescription])
            if nuevoModo == .adoptables { errorInventario = "No se pudo iniciar la búsqueda. \(error.localizedDescription)" }
            modo = nil
        }
    }

    private func recibir(_ datos: Data) {
        let (lineas, parcial) = terminal.procesar(datos)
        var visibles: [String] = []
        for linea in lineas {
            if linea.hasPrefix("\u{1E}") {
                registro.agregar(visibles)
                visibles.removeAll()
                marca(String(linea.dropFirst()).components(separatedBy: "\u{1F}"))
            } else {
                if linea.contains("Sorry, try again") || linea.contains("Lo siento, vuelva a intentarlo") {
                    claveIncorrecta = true
                }
                visibles.append(linea)
                avanzar(linea)
            }
        }
        registro.agregar(visibles)
        if let ultima = visibles.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            let limpia = ultima.trimmingCharacters(in: .whitespaces)
            if limpia != ultimaLinea { ultimaLinea = limpia }
        }
        if !lineas.isEmpty { respondiClave = false }
        // Cada cambio publicado redibuja toda la ventana: solo si de verdad cambio
        if parcial != lineaParcial {
            lineaParcial = parcial
            avanzar(parcial)
        }
        detectarClave(parcial)
    }

    /// sudo (directo o desde brew/mas/installer) deja la pregunta sin salto de linea
    private func detectarClave(_ parcial: String) {
        guard !respondiClave, !pidiendoClave else { return }
        let p = parcial.trimmingCharacters(in: .whitespaces).lowercased()
        guard p.hasSuffix(":"), p.contains("password") || p.contains("contraseña") || p.contains("passphrase") else { return }
        textoClave = parcial.trimmingCharacters(in: .whitespaces)
        pidiendoClave = true
        abrirPrincipal?()
        NSApp.requestUserAttention(.criticalRequest)
    }

    private func indice(_ id: String) -> Int? { etapas.firstIndex { $0.id == id } }

    private func marca(_ c: [String]) {
        func campo(_ i: Int) -> String { i < c.count ? c[i] : "" }
        switch campo(0) {
        case "ETAPA":
            let id = campo(1)
            itemsEnCurso[id] = []
            notasEnCurso[id] = []
            etapasCorridas.insert(id)
            if let i = indice(id) {
                etapas[i].estado = campo(2) == "revisar" ? .revisando : .instalando
                etapas[i].mensaje = nil
                if campo(2) == "instalar" {
                    etapaActual = id
                    itemTrabajando = nil
                    for item in etapas[i].items where avances[item.id]?.fase == .enCola {
                        avances[item.id] = Avance(fase: .trabajando, fraccion: nil)
                    }
                }
            }
        case "ITEM":
            let url = campo(6)
            let item = Item(etapa: campo(1), clave: campo(2), nombre: campo(3), actual: campo(4), nueva: campo(5),
                            url: url.isEmpty ? nil : url)
            itemsEnCurso[item.etapa, default: []].append(item)
        case "NOTA":
            notasEnCurso[campo(1), default: []].append(campo(2))
        case "FIN":
            finEtapa(campo(1), estado: campo(2), codigo: campo(4))
        case "AUTORIZACION":
            esperandoAutorizacion = true
        case "AUTORIZADO":
            esperandoAutorizacion = false
            pidiendoClave = false
        case "FIN_AUTORIZACION":
            esperandoAutorizacion = false
            pidiendoClave = false
            if campo(1) == "error" { falloAutorizacion = true }
        case "ADOPTABLE":
            adoptablesEnCurso.append(Adoptable(token: campo(1), nombre: campo(2), ruta: campo(3), instalada: campo(4),
                                               version: campo(5), estado: Adoptable.Estado(rawValue: campo(6)) ?? .sincask))
        case "ADOPTADA":
            resultadosAdopcion[campo(1)] = campo(2) == "ok"
        default:
            break
        }
    }

    private func finEtapa(_ id: String, estado: String, codigo: String) {
        guard let i = indice(id) else { return }
        let nuevos = itemsEnCurso[id] ?? []
        let notas = notasEnCurso[id] ?? []
        if etapaActual == id { etapaActual = nil }
        if modo == .instalar { cerrarAvances(id, estado: estado, pendientes: estado == "pendiente" ? nuevos : []) }
        if estado == "pausada" {
            etapas[i].items = []
            etapas[i].notas = notas
            etapas[i].estado = .pausada
            etapas[i].mensaje = "En pausa"
            etapasElegidas.remove(id)
            elegidos = elegidos.filter { !$0.hasPrefix("\(id)/") }
            actualizarInsignia()
            return
        }
        if modo == .revisar {
            etapas[i].items = nuevos
            etapas[i].notas = notas
            etapas[i].estado = estado == "error" ? .error : (nuevos.isEmpty ? .alDia : .pendiente)
            if estado == "error" { etapas[i].mensaje = "No se pudo revisar del todo" }
            // Lo nuevo queda elegido; lo que el usuario desmarco antes se respeta
            for item in nuevos where !pendientesAntes.contains(item.id) { elegidos.insert(item.id) }
            if etapas[i].def.seleccion == .porEtapa {
                // Se vuelve a marcar sola solo si aparecio algo nuevo
                if nuevos.isEmpty {
                    etapasElegidas.remove(id)
                } else if nuevos.contains(where: { !pendientesAntes.contains($0.id) }) {
                    etapasElegidas.insert(id)
                }
            }
            elegidos = elegidos.filter { idItem in !idItem.hasPrefix("\(id)/") || nuevos.contains { $0.id == idItem } }
        } else {
            etapas[i].notas = notas
            switch estado {
            case "error":
                etapas[i].estado = .error
                etapas[i].mensaje = "Terminó con errores (código \(codigo)); revisa el registro"
            case "pendiente":
                // Avisos manuales o lo que quedo pendiente despues de instalar
                etapas[i].items = nuevos
                etapas[i].estado = .pendiente
            default:
                etapas[i].items.removeAll { instalandoItems.contains($0.id) }
                etapas[i].estado = etapas[i].items.isEmpty ? .hecho : .pendiente
                etapas[i].mensaje = "Actualizado"
            }
            if etapas[i].def.seleccion == .porEtapa && etapas[i].estado != .error && etapas[i].items.isEmpty {
                etapasElegidas.remove(id)
            }
        }
        actualizarInsignia()
    }

    private func terminado(_ codigo: Int32) {
        let resto = terminal.vaciar()
        if !resto.isEmpty { registro.agregar([resto]) }
        lineaParcial = ""
        let modoTerminado = modo ?? .revisar
        let cancelo = cancelado || codigo == 130 || codigo == 129 || codigo == 143
        ultimoModoTerminado = modoTerminado
        if modoTerminado == .adoptables || modoTerminado == .adoptar {
            terminadoAdopcion(modoTerminado, codigo: codigo, cancelo: cancelo)
            return
        }
        for i in etapas.indices where etapas[i].estado.enCurso {
            etapas[i].estado = .interrumpida
            etapas[i].mensaje = cancelo ? "Cancelado" : "Se interrumpió"
        }
        modo = nil
        etapaActual = nil
        avances = [:]
        proceso = nil
        IconosApps.recargar()
        pidiendoClave = false
        esperandoAutorizacion = false
        if modoTerminado == .revisar && !cancelo {
            ultimaRevision = Date()
            defaults.set(ultimaRevision, forKey: "ultimaRevision")
        }
        var errores = etapas
            .filter { etapasCorridas.contains($0.id) && ($0.estado == .error || (!cancelo && $0.estado == .interrumpida)) }
            .map(\.def.titulo)
        if !cancelo {
            if falloAutorizacion {
                errores.append("la autorización de sudo")
            } else if codigo != 0 && errores.isEmpty && modoTerminado == .instalar {
                errores.append("el motor (código \(codigo))")
            }
        }
        let archivo = guardarRegistro(modoTerminado)
        resultado = Resultado(modo: modoTerminado, codigo: codigo, duracion: Date().timeIntervalSince(inicio),
                              cancelado: cancelo, errores: errores, pendientes: totalPendientes, archivo: archivo)
        actualizarInsignia()
        notificar(modoTerminado, cancelo: cancelo, errores: errores)
    }

    private func terminadoAdopcion(_ modoTerminado: Modo, codigo: Int32, cancelo: Bool) {
        modo = nil
        proceso = nil
        pidiendoClave = false
        esperandoAutorizacion = false
        if modoTerminado == .adoptables {
            if !cancelo && codigo == 0 {
                adoptables = adoptablesEnCurso
                // Reemplazar una app requiere elegirla expresamente en la lista.
                adoptablesElegidos = []
                adoptablesBuscados = true
            } else if !cancelo {
                // Una lista parcial o vacía tras un fallo no sustituye el último inventario completo.
                errorInventario = "No se pudieron revisar las apps (código \(codigo)). Vuelve a buscar."
            }
        }
        _ = guardarRegistro(modoTerminado)
        if modoTerminado == .adoptar {
            IconosApps.recargar()
            // Las adoptadas pasan a "Ya en Homebrew": se vuelve a mirar, sin perder los resultados
            if !cancelo && resultadosAdopcion.values.contains(true) { buscarAdoptables(conservarResultados: true) }
        }
    }

    // MARK: Avance por app

    /// Mueve la barra de cada app con lo que va escribiendo brew; de las demas fuentes solo se sabe
    /// cuando aparecen en la salida y, si dan porcentaje, cuanto llevan
    private func avanzar(_ linea: String) {
        guard modo == .instalar, let etapa = etapaActual, let i = indice(etapa), !linea.isEmpty else { return }
        let items = etapas[i].items.filter { avances[$0.id]?.fase == .trabajando }
        guard !items.isEmpty else { return }
        func item(_ clave: Substring) -> Item? { items.first { $0.clave == clave } }

        // Descargas en paralelo de brew 7, a veces varias en una linea:
        // "⠞ Bottle node (26.13.0)  #####   Downloading  5.4MB/ 21.3MB"
        for m in linea.matches(of: #/(\S+) \([^)]*\)[ #]*Downloading +([\d.]+) ?([KMGT]?B) *\/ *([\d.]+) ?([KMGT]?B)/#) {
            if let it = item(m.1), let llevado = bytes(m.2, m.3), let total = bytes(m.4, m.5), total > 0 {
                mover(it.id, 0.05 + 0.55 * min(llevado / total, 1))
            }
        }
        // "✔︎ Cask onedrive (26.189.0928.0009)": descarga lista (el ✔︎ lleva selector de variante)
        for m in linea.matches(of: #/✔\S* (?:Bottle|Cask|Formula) (\S+) \(/#.matchingSemantics(.unicodeScalar)) {
            if let it = item(m.1) { mover(it.id, 0.6) }
        }

        let texto = linea.trimmingCharacters(in: .whitespaces)
        if let m = texto.wholeMatch(of: #/==> (?:Upgrading|Installing|Reinstalling) (\S+)/#), let it = item(m.1) {
            itemTrabajando = it.id
            mover(it.id, 0.7)
        } else if let m = texto.firstMatch(of: #/^(\S+) was successfully (?:upgraded|installed|reinstalled)/#), let it = item(m.1) {
            terminarAvance(it.id)
        } else if let m = texto.firstMatch(of: #/\/Cellar\/([^\/]+)\/[^:]+: [\d,]+ files/#), let it = item(m.1) {
            terminarAvance(it.id)
        } else if let actual = itemTrabajando, texto.hasPrefix("==> ") {
            // Pasos de la instalacion ("Pouring", "Moving App", "Running installer"): un poco cada uno
            mover(actual, min((avances[actual]?.fraccion ?? 0.7) + 0.05, 0.95))
        } else if let actual = itemTrabajando, let m = texto.firstMatch(of: #/(\d{1,3}(?:\.\d+)?) ?%/#),
                  let p = Double(m.1), p <= 100 {
            mover(actual, 0.05 + 0.55 * p / 100)
        } else if etapa != "formulas" && etapa != "casks",
                  let it = items.first(where: { $0.nombre.count >= 3 && texto.localizedCaseInsensitiveContains($0.nombre) }) {
            itemTrabajando = it.id
        }
    }

    private func bytes(_ valor: Substring, _ unidad: Substring) -> Double? {
        guard let v = Double(valor), let potencia = ["B", "KB", "MB", "GB", "TB"].firstIndex(of: String(unidad)) else { return nil }
        return v * pow(1024, Double(potencia))
    }

    /// La barra solo avanza; los cambios minimos no se publican (cada uno redibuja la ventana)
    private func mover(_ id: String, _ fraccion: Double) {
        guard let avance = avances[id], avance.fase == .trabajando else { return }
        if let anterior = avance.fraccion, fraccion < anterior + 0.01 { return }
        avances[id] = Avance(fase: .trabajando, fraccion: fraccion)
    }

    private func terminarAvance(_ id: String) {
        avances[id] = Avance(fase: .hecho, fraccion: 1)
        if itemTrabajando == id { itemTrabajando = nil }
    }

    /// Al terminar una etapa lo que no quedo pendiente se da por hecho, o con error si la etapa fallo
    private func cerrarAvances(_ id: String, estado: String, pendientes: [Item]) {
        for (clave, avance) in avances where clave.hasPrefix("\(id)/") && avance.fase != .hecho {
            if estado == "pausada" || pendientes.contains(where: { $0.id == clave }) {
                avances[clave] = nil
            } else if estado == "error" {
                avances[clave] = Avance(fase: .error, fraccion: avance.fraccion ?? 0)
            } else {
                avances[clave] = Avance(fase: .hecho, fraccion: 1)
            }
        }
        itemTrabajando = nil
    }

    // MARK: Salidas

    private func guardarRegistro(_ modo: Modo) -> URL? {
        let fm = FileManager.default
        let carpeta = Controlador.carpetaRegistros
        try? fm.createDirectory(at: carpeta, withIntermediateDirectories: true)
        let formato = DateFormatter()
        formato.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let archivo = carpeta.appendingPathComponent("\(formato.string(from: inicio))-\(modo.nombreRegistro).log")
        do {
            try (registro.texto + "\n").write(to: archivo, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        // Se guardan los ultimos 60
        if let todos = try? fm.contentsOfDirectory(at: carpeta, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "log" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }), todos.count > 60 {
            todos.dropFirst(60).forEach { try? fm.removeItem(at: $0) }
        }
        return archivo
    }

    func actualizarInsignia() {
        let n = totalPendientes
        NSApp?.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    private func notificar(_ modo: Modo, cancelo: Bool, errores: [String]) {
        guard Bundle.main.bundleIdentifier != nil, defaults.object(forKey: "notificar") as? Bool ?? true else { return }
        let n = totalPendientes
        let titulo: String
        let cuerpo: String
        switch modo {
        case .revisar:
            let nuevos = Set(etapas.flatMap { $0.items.map(\.id) }).subtracting(pendientesAntes)
            // En segundo plano solo avisa si aparecio algo nuevo; con la app al frente no hace falta
            guard !cancelo, n > 0, !(NSApp?.isActive ?? false), !silencioso || !nuevos.isEmpty else { return }
            titulo = "Hay \(n) actualizaciones"
            cuerpo = etapas.filter { !$0.items.isEmpty }.map { "\($0.def.titulo): \($0.items.count)" }.joined(separator: ", ")
        case .adoptables, .adoptar:
            return
        case .instalar:
            guard !(NSApp?.isActive ?? false) else { return }
            if cancelo {
                titulo = "Actualización cancelada"
                cuerpo = "Revisa el registro para ver hasta dónde llegó."
            } else if errores.isEmpty {
                titulo = "Actualizate terminó"
                cuerpo = n > 0 ? "Sin errores. Quedan \(n) pendientes o manuales." : "Sin errores. Todo al día."
            } else {
                titulo = "Actualizate terminó con errores"
                cuerpo = errores.joined(separator: ", ")
            }
        }
        let contenido = UNMutableNotificationContent()
        contenido.title = titulo
        contenido.body = cuerpo
        contenido.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: contenido, trigger: nil))
    }
}
