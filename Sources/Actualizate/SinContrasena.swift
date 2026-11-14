import AppKit
import RaizComun
import Security
import ServiceManagement

/// "Actualizar sin contraseña": registra el ayudante root de la app (macOS lo aprueba una vez en
/// Elementos de inicio) y le pide que instale la regla de sudo para los comandos de las actualizaciones.
@MainActor
final class SinContrasena: ObservableObject {
    static let compartido = SinContrasena()

    enum Estado: Equatable {
        case inactivo
        /// Esta copia no trae el ayudante (se compilo sin una firma de Apple)
        case noDisponible
        /// Registrado, falta que el usuario lo active en Ajustes del Sistema
        case esperandoAprobacion
        case trabajando
        case activo
        /// La regla sigue en /etc aunque el ayudante esta apagado o no registrado
        case reglaSuelta
        /// `quitando`: fallo al quitar, y reintentar es volver a quitar
        case error(String, quitando: Bool)
    }

    @Published private(set) var estado: Estado = .inactivo

    static let pregunta = "¿Actualizar sin contraseña?"
    static let explicacion = """
        Instala un ayudante de Actualizate que macOS te pide aprobar una vez, en Elementos de inicio. \
        Después, las actualizaciones de Homebrew, App Store y los instaladores .pkg no piden contraseña ni Touch ID.

        El ayudante solo pone o quita una regla de sudo para los comandos que usan esas actualizaciones \
        (installer, launchctl, pkgutil, rm, cp…) y solo atiende a esta app. Cualquier programa que corra con \
        tu usuario también podría usar esos comandos como administrador sin que se te pregunte.

        Puedes quitarlo cuando quieras en Ajustes.
        """

    private let servicio = SMAppService.daemon(plistName: Raiz.plist)
    private let defaults = UserDefaults.standard
    /// Lo que quiere el usuario: el estado de macOS solo dice si el ayudante esta registrado
    private let claveQuerido = "sinContrasena"
    /// Huella del ayudante registrado: si cambia (app nueva), macOS pide volver a registrarlo
    private let claveHuella = "sinContrasenaAyudante"
    private var observador: NSObjectProtocol?

    private init() {
        // La aprobacion se da en Ajustes del Sistema: al volver a la app se mira si ya esta
        observador = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SinContrasena.compartido.comprobar() }
        }
    }

    private var querido: Bool { defaults.bool(forKey: claveQuerido) }
    private var reglaPuesta: Bool { FileManager.default.fileExists(atPath: Raiz.regla) }

    /// Lee el estado en macOS; con el ayudante aprobado deja la regla al dia con la de esta version
    func comprobar() {
        guard estado != .trabajando else { return }
        guard huellaAyudante() != nil else {
            estado = reglaPuesta ? .reglaSuelta : .noDisponible
            return
        }
        switch servicio.status {
        case .enabled where querido:
            if defaults.string(forKey: claveHuella) != huellaAyudante() {
                reregistrar()
            } else if estado != .activo {
                pedirRegla()
            }
        case .enabled:
            // Se quiso quitar y no se pudo del todo
            estado = .error("El ayudante sigue registrado.", quitando: true)
        case _ where reglaPuesta:
            // Apagado en Elementos de inicio, o la app se movio: la regla quedo sin quien la quite
            estado = .reglaSuelta
        case .requiresApproval where querido:
            estado = .esperandoAprobacion
        default:
            estado = .inactivo
        }
    }

    func activar() {
        guard estado != .trabajando else { return }
        defaults.set(true, forKey: claveQuerido)
        registrar(abrirAjustes: true)
    }

    func desactivar() {
        guard estado != .trabajando else { return }
        defaults.set(false, forKey: claveQuerido)
        estado = .trabajando
        guard servicio.status == .enabled else {
            terminarDesactivar()
            return
        }
        // Primero la regla, mientras el ayudante este para quitarla
        llamar({ $0.quitarRegla(respuesta: $1) }) { _ in self.terminarDesactivar() }
    }

    func abrirAjustesDelSistema() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func registrar(abrirAjustes: Bool) {
        if servicio.status == .enabled && defaults.string(forKey: claveHuella) != huellaAyudante() {
            reregistrar()
            return
        }
        do {
            try servicio.register()
        } catch {
            // Sin aprobar todavia, register() tambien falla: lo que cuenta es el estado que queda
            if servicio.status != .requiresApproval && servicio.status != .enabled {
                estado = .error("macOS no dejó registrar el ayudante: \(error.localizedDescription)", quitando: false)
                return
            }
        }
        defaults.set(huellaAyudante(), forKey: claveHuella)
        if servicio.status == .requiresApproval {
            estado = .esperandoAprobacion
            if abrirAjustes { SMAppService.openSystemSettingsLoginItems() }
        } else {
            pedirRegla()
        }
    }

    /// macOS pide volver a registrar el ayudante cuando cambia su ejecutable (al instalar una version nueva)
    private func reregistrar() {
        estado = .trabajando
        servicio.unregister { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.estado = .inactivo
                    self.registrar(abrirAjustes: false)
                }
            }
        }
    }

    private func terminarDesactivar() {
        // Si el ayudante no pudo, la regla misma deja borrarla sin contrasena (rm esta en ella)
        if reglaPuesta { borrarReglaConSudo() }
        try? servicio.unregister()
        if reglaPuesta {
            estado = .error("No se pudo quitar la regla. En Terminal: sudo rm \(Raiz.regla)", quitando: true)
        } else if servicio.status == .enabled {
            estado = .error("Se quitó la regla, pero macOS no dejó quitar el ayudante. Quítalo en Elementos de inicio.",
                            quitando: true)
        } else {
            estado = .inactivo
        }
    }

    private func borrarReglaConSudo() {
        let rm = Process()
        rm.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        rm.arguments = ["-n", "/bin/rm", "-f", Raiz.regla]
        rm.standardOutput = FileHandle.nullDevice
        rm.standardError = FileHandle.nullDevice
        try? rm.run()
        rm.waitUntilExit()
    }

    private func pedirRegla() {
        estado = .trabajando
        llamar({ $0.instalarRegla(respuesta: $1) }) { error in
            self.estado = error.map { .error($0, quitando: false) } ?? .activo
        }
    }

    /// cdhash del ayudante que trae esta copia de la app; nil si no lo trae
    private func huellaAyudante() -> String? {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "ActualizateRaiz") else { return nil }
        var codigo: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &codigo) == errSecSuccess, let codigo,
              SecCodeCopySigningInformation(codigo, [], &info) == errSecSuccess,
              let unico = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unico.map { String(format: "%02x", $0) }.joined()
    }

    /// Una peticion al ayudante por su servicio XPC; `listo` recibe el error o nil
    private func llamar(_ peticion: @escaping (ServicioRaiz, @escaping (String?) -> Void) -> Void,
                        listo: @escaping @MainActor (String?) -> Void) {
        let conexion = NSXPCConnection(machServiceName: Raiz.servicio, options: .privileged)
        conexion.remoteObjectInterface = NSXPCInterface(with: ServicioRaiz.self)
        var respondido = false
        let responder: (String?) -> Void = { error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard !respondido else { return }
                    respondido = true
                    conexion.invalidate()
                    listo(error)
                }
            }
        }
        conexion.resume()
        let proxy = conexion.remoteObjectProxyWithErrorHandler { error in
            responder("No se pudo hablar con el ayudante: \(error.localizedDescription)")
        }
        guard let servicio = proxy as? ServicioRaiz else {
            responder("El ayudante no responde como se esperaba.")
            return
        }
        peticion(servicio, responder)
        // Si launchd no llega a lanzarlo, ni la respuesta ni el error llegan nunca
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { responder("El ayudante no respondió a tiempo.") }
    }
}
