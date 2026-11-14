import Foundation
import RaizComun
import Security

// Ayudante root de Actualizate. launchd lo lanza cuando la app se conecta a su servicio XPC
// (Contents/Library/LaunchDaemons/local.armando.actualizar.raiz.plist) y termina al cerrarse la conexion.

/// Solo atiende a la app (su identificador) firmada por el mismo equipo de Apple que este ayudante. Se arma
/// con la firma del propio ayudante, que macOS comprueba al lanzarlo, y no con la de la app, que esta en una
/// carpeta que el usuario puede escribir
func requisitoDeLaApp() -> String? {
    var yo: SecCode?
    guard SecCodeCopySelf([], &yo) == errSecSuccess, let yo else { return nil }
    var estatico: SecStaticCode?
    guard SecCodeCopyStaticCode(yo, [], &estatico) == errSecSuccess, let estatico else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(estatico, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let equipo = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
          equipo.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { return nil }
    return #"identifier "local.armando.actualizar" and anchor apple generic and certificate leaf[subject.OU] = "\#(equipo)""#
}

/// Una peticion a la vez, y el proceso no termina a mitad de escribir la regla
let cerrojo = NSLock()

final class Servicio: NSObject, ServicioRaiz {
    private let uid: uid_t

    init(uid: uid_t) {
        self.uid = uid
    }

    func instalarRegla(respuesta: @escaping (String?) -> Void) {
        cerrojo.lock()
        defer { cerrojo.unlock() }
        guard let usuario = Regla.administrador(uid: uid) else {
            respuesta("Solo una cuenta de administrador puede activarlo.")
            return
        }
        respuesta(Regla.instalar(usuario: usuario))
    }

    func quitarRegla(respuesta: @escaping (String?) -> Void) {
        cerrojo.lock()
        defer { cerrojo.unlock() }
        guard Regla.administrador(uid: uid) != nil else {
            respuesta("Solo una cuenta de administrador puede quitarlo.")
            return
        }
        respuesta(Regla.quitar())
    }
}

final class Oyente: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conexion: NSXPCConnection) -> Bool {
        conexion.exportedInterface = NSXPCInterface(with: ServicioRaiz.self)
        conexion.exportedObject = Servicio(uid: conexion.effectiveUserIdentifier)
        conexion.invalidationHandler = {
            cerrojo.lock()
            exit(0)
        }
        conexion.resume()
        return true
    }
}

guard let requisito = requisitoDeLaApp() else {
    // Sin firma de Apple no hay forma de saber quien llama: no se atiende a nadie
    exit(1)
}
let oyente = Oyente()
let listener = NSXPCListener(machServiceName: Raiz.servicio)
// Quien no cumpla la firma se rechaza antes de llegar al delegado
listener.setConnectionCodeSigningRequirement(requisito)
listener.delegate = oyente
listener.resume()
dispatchMain()
