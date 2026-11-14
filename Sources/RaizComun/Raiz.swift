import Foundation

/// Ayudante root de Actualizate: un LaunchDaemon dentro de la app que macOS aprueba una vez en
/// Elementos de inicio. Instala la regla de sudo para que las actualizaciones no pidan contrasena.
public enum Raiz {
    /// Servicio XPC del ayudante (y Label de su plist)
    public static let servicio = "local.armando.actualizar.raiz"
    /// Plist en Contents/Library/LaunchDaemons
    public static let plist = "local.armando.actualizar.raiz.plist"
    /// La regla de sudo. Sin punto en el nombre (sudo se salta esos archivos) y despues de brew_setenv
    public static let regla = "/etc/sudoers.d/zz_actualizate"
}

@objc public protocol ServicioRaiz {
    /// Instala o pone al dia la regla para el usuario que llama; responde el error, o nil si salio bien
    func instalarRegla(respuesta: @escaping (String?) -> Void)
    /// Borra la regla; responde el error, o nil si salio bien
    func quitarRegla(respuesta: @escaping (String?) -> Void)
}
