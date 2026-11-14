import AppKit
import Foundation

enum Seleccion {
    /// Se elige cada elemento (brew, mas, casks propios)
    case porItem
    /// La etapa se instala completa (sparkle-pendientes, msupdate)
    case porEtapa
    /// Solo aviso: se instala a mano
    case manual
}

struct DefinicionEtapa {
    let id: String
    let titulo: String
    /// Nombre corto para las fichas y la barra de menus
    let corto: String
    let simbolo: String
    let seleccion: Seleccion
    let ayuda: String

    // Mismo orden y mismos ids que ETAPAS en el motor
    static let todas: [DefinicionEtapa] = [
        .init(id: "propios", titulo: "Casks propios (tap local)", corto: "Casks propios", simbolo: "shippingbox",
              seleccion: .porItem, ayuda: "Sube la versión en el tap, descarga para calcular el sha256 y actualiza con brew."),
        .init(id: "formulas", titulo: "Homebrew: fórmulas", corto: "Fórmulas", simbolo: "terminal",
              seleccion: .porItem, ayuda: "brew upgrade --formula"),
        .init(id: "casks", titulo: "Homebrew: apps", corto: "Apps de Homebrew", simbolo: "macwindow",
              seleccion: .porItem, ayuda: "brew upgrade --cask --greedy, sin las apps que ya se actualizaron solas."),
        .init(id: "mas", titulo: "Mac App Store", corto: "App Store", simbolo: "bag",
              seleccion: .porItem, ayuda: "mas upgrade"),
        .init(id: "sparkle", titulo: "Apps con Sparkle", corto: "Sparkle", simbolo: "sparkles",
              seleccion: .porEtapa, ayuda: "Se instalan juntas con sparkle-cli después de Homebrew; lo que brew ya actualizó no se repite."),
        .init(id: "manuales", titulo: "Apps sin brew ni Sparkle", corto: "Apps manuales", simbolo: "hand.raised",
              seleccion: .manual, ayuda: "Hay que descargarlas e instalarlas a mano."),
        .init(id: "macos", titulo: "macOS y Safari", corto: "macOS", simbolo: "apple.logo",
              seleccion: .manual, ayuda: "Suelen pedir reinicio: se instalan desde Ajustes del Sistema."),
        .init(id: "microsoft", titulo: "Microsoft", corto: "Microsoft", simbolo: "square.grid.2x2",
              seleccion: .porEtapa, ayuda: "Microsoft AutoUpdate. Si le falta su ayudante de instalación, lo repara antes de instalar."),
    ]
}

/// Iconos reales de las apps de cada actualizacion, buscados por nombre en las carpetas de apps.
@MainActor
enum IconosApps {
    private static var indice: [String: String]?
    // Tambien guarda los "sin icono" para no repetir la busqueda en cada redibujo
    private static var cache: [String: NSImage?] = [:]

    static func icono(_ item: Item) -> NSImage? {
        if let guardado = cache[item.id] { return guardado }
        let imagen = ruta(item).map { NSWorkspace.shared.icon(forFile: $0) }
        cache[item.id] = .some(imagen)
        return imagen
    }

    /// Simbolo de respaldo cuando no hay app (formulas de brew, updates sin app)
    static func simbolo(_ item: Item) -> String {
        switch item.etapa {
        case "formulas": return "terminal.fill"
        case "macos": return "apple.logo"
        default: return "app.dashed"
        }
    }

    /// Se vuelve a leer en cada revision: pueden haber aparecido o cambiado apps
    static func recargar() {
        indice = nil
        cache.removeAll()
    }

    private static func ruta(_ item: Item) -> String? {
        if item.etapa == "formulas" { return nil }
        if item.etapa == "macos" {
            return item.nombre.localizedCaseInsensitiveContains("safari") ? "/Applications/Safari.app"
                : "/System/Applications/System Settings.app"
        }
        let apps = cargarIndice()
        let candidatos = [normalizar(item.nombre), normalizar(item.clave)].filter { $0.count >= 3 }
        for c in candidatos { if let ruta = apps[c] { return ruta } }
        // "WhatsApp Messenger" -> WhatsApp.app, "Microsoft Word 16.103" -> Microsoft Word.app
        var mejor: (largo: Int, ruta: String)?
        for (nombre, ruta) in apps where nombre.count >= 4 {
            for c in candidatos where c.hasPrefix(nombre) || nombre.hasPrefix(c) {
                let largo = min(nombre.count, c.count)
                // Empates por ruta para que el resultado no dependa del orden del diccionario
                if largo > (mejor?.largo ?? 0) || (largo == mejor?.largo && ruta < (mejor?.ruta ?? "")) {
                    mejor = (largo, ruta)
                }
            }
        }
        return mejor?.ruta
    }

    private static func cargarIndice() -> [String: String] {
        if let indice { return indice }
        var nuevo: [String: String] = [:]
        let fm = FileManager.default
        let carpetas = ["/Applications", "/Applications/Utilities", "/System/Applications",
                        fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for carpeta in carpetas {
            guard let nombres = try? fm.contentsOfDirectory(atPath: carpeta) else { continue }
            for nombre in nombres {
                let ruta = (carpeta as NSString).appendingPathComponent(nombre)
                // Gana la primera: /Applications antes que las del sistema
                if nombre.hasSuffix(".app") {
                    let clave = normalizar(String(nombre.dropLast(4)))
                    if nuevo[clave] == nil { nuevo[clave] = ruta }
                } else if let dentro = try? fm.contentsOfDirectory(atPath: ruta) {
                    // Apps dentro de una carpeta del fabricante (/Applications/Fabricante/App.app)
                    for app in dentro where app.hasSuffix(".app") {
                        let clave = normalizar(String(app.dropLast(4)))
                        if nuevo[clave] == nil { nuevo[clave] = (ruta as NSString).appendingPathComponent(app) }
                    }
                }
            }
        }
        indice = nuevo
        return nuevo
    }

    private static func normalizar(_ texto: String) -> String {
        texto.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}

enum Estado: Equatable {
    case sinRevisar, revisando, alDia, pendiente, error, instalando, hecho, interrumpida, pausada

    var enCurso: Bool { self == .revisando || self == .instalando }
}

struct Item: Identifiable, Hashable {
    let etapa: String
    let clave: String
    let nombre: String
    let actual: String
    let nueva: String
    let url: String?

    var id: String { "\(etapa)/\(clave)" }
}

/// Avance de una app mientras se actualiza: la barra de su fila
struct Avance: Equatable {
    enum Fase { case enCola, trabajando, hecho, error }
    var fase: Fase = .enCola
    /// nil mientras no se sabe cuanto falta (barra indeterminada)
    var fraccion: Double? = 0
}

struct EtapaEstado: Identifiable {
    let def: DefinicionEtapa
    var estado: Estado = .sinRevisar
    var items: [Item] = []
    var notas: [String] = []
    var mensaje: String?

    var id: String { def.id }
}

/// Convierte la salida cruda de la terminal en lineas de texto: quita secuencias ANSI y aplica \r
/// y backspace como lo haria una terminal en una sola linea.
struct Terminal {
    private var resto = Data()

    mutating func procesar(_ datos: Data) -> (lineas: [String], parcial: String) {
        resto.append(datos)
        var lineas: [String] = []
        if let ultimo = resto.lastIndex(of: 0x0A) {
            let completas = resto[resto.startIndex...ultimo]
            resto = Data(resto[resto.index(after: ultimo)...])
            for linea in completas.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
                lineas.append(Terminal.limpiar(String(decoding: linea, as: UTF8.self)))
            }
        }
        if resto.count > 1 << 16 {
            // Una linea enorme sin salto (barra de progreso eterna): se corta
            lineas.append(Terminal.limpiar(String(decoding: resto, as: UTF8.self)))
            resto.removeAll()
        }
        return (lineas, Terminal.limpiar(String(decoding: resto, as: UTF8.self)))
    }

    mutating func vaciar() -> String {
        defer { resto.removeAll() }
        return Terminal.limpiar(String(decoding: resto, as: UTF8.self))
    }

    static func limpiar(_ texto: String) -> String {
        let u = Array(texto.unicodeScalars)
        var salida = String.UnicodeScalarView()
        var i = 0
        while i < u.count {
            let c = u[i]
            i += 1
            switch c {
            case "\u{1B}":
                guard i < u.count else { break }
                let tipo = u[i]
                i += 1
                if tipo == "[" {
                    // CSI: parametros hasta un byte final 0x40...0x7E
                    while i < u.count, !(0x40...0x7E).contains(u[i].value) { i += 1 }
                    i += 1
                } else if tipo == "]" {
                    // OSC: hasta BEL o ESC \
                    while i < u.count, u[i] != "\u{07}", u[i] != "\u{1B}" { i += 1 }
                    i += (i < u.count && u[i] == "\u{1B}") ? 2 : 1
                }
            case "\r":
                // Si no viene nada despues es el fin de la linea (\r\n); si no, se reescribe
                if i < u.count { salida.removeAll() }
            case "\u{08}":
                if !salida.isEmpty { salida.removeLast() }
            case "\u{07}", "\u{00}":
                break
            default:
                salida.append(c)
            }
        }
        return String(salida)
    }
}

/// Registro de la salida: lo guarda y lo pinta en un NSTextView si hay uno a la vista.
final class Registro {
    private(set) var lineas: [String] = []
    private let maximo = 30000
    weak var vista: NSTextView? {
        didSet { recargar() }
    }

    func agregar(_ nuevas: [String]) {
        guard !nuevas.isEmpty else { return }
        lineas.append(contentsOf: nuevas)
        var recorte = 0
        if lineas.count > maximo {
            recorte = lineas.count - maximo
            lineas.removeFirst(recorte)
        }
        guard let vista, let texto = vista.textStorage else { return }
        if recorte > 0 {
            recargar()
            return
        }
        let alFinal = vista.visibleRect.maxY >= vista.bounds.maxY - 40
        texto.beginEditing()
        for linea in nuevas { texto.append(Registro.atribuido(linea)) }
        texto.endEditing()
        if alFinal { vista.scrollToEndOfDocument(nil) }
    }

    func limpiar() {
        lineas.removeAll()
        vista?.textStorage?.setAttributedString(NSAttributedString())
    }

    var texto: String { lineas.joined(separator: "\n") }

    private func recargar() {
        guard let vista, let texto = vista.textStorage else { return }
        let todo = NSMutableAttributedString()
        for linea in lineas { todo.append(Registro.atribuido(linea)) }
        texto.setAttributedString(todo)
        vista.scrollToEndOfDocument(nil)
    }

    static let fuente = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    static let fuenteNegrita = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)

    static func atribuido(_ linea: String) -> NSAttributedString {
        var color = NSColor.textColor
        var fuente = Registro.fuente
        let minusculas = linea.lowercased()
        if linea.hasPrefix("==>") {
            color = .controlAccentColor
            fuente = Registro.fuenteNegrita
        } else if minusculas.hasPrefix("error") || minusculas.contains(" error:") || minusculas.contains("fallo")
                    || minusculas.contains("failed") || minusculas.contains("no se pudo") || minusculas.contains("descartado") {
            color = .systemRed
        } else if minusculas.hasPrefix("warning") || minusculas.contains("aviso") || minusculas.contains("a mano") {
            color = .systemOrange
        } else if linea.contains(" -> ") {
            color = .labelColor
        } else if linea.hasPrefix("  ") {
            color = .secondaryLabelColor
        }
        return NSAttributedString(string: linea + "\n", attributes: [.font: fuente, .foregroundColor: color])
    }
}

/// App instalada en la Mac y su estado frente a Homebrew
struct Adoptable: Identifiable, Hashable {
    enum Estado: String {
        /// Se instala la copia de Homebrew con respaldo previo de la original
        case si
        /// El cask se instala con paquete: adoptarla es reinstalarla con su instalador oficial
        case paquete
        /// La version del cask no coincide: brew no la adopta
        case version
        /// Ya la maneja un cask instalado
        case brew
        case mas
        case apple
        /// Homebrew no tiene cask para ella
        case sincask
        /// Tiene cask, pero esta copia no esta en el destino que gestiona Homebrew
        case fuera
        /// Su cask esta retirado en Homebrew
        case deshabilitado

        var adoptable: Bool { self == .si || self == .paquete || self == .fuera }
    }

    let token: String
    let nombre: String
    let ruta: String
    let instalada: String
    let version: String
    let estado: Estado

    /// Puede haber varias apps sin cask o dos copias del mismo cask: la ruta es lo unico que no se repite
    var id: String { ruta }
}
