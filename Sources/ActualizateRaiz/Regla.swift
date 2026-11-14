import Foundation
import RaizComun

/// /etc/sudoers.d/zz_actualizate: los comandos que usan brew, mas y los instaladores al actualizar corren
/// con sudo sin contrasena ni Touch ID.
///
/// - El nombre tiene que ordenar despues de brew_setenv ("%admin ALL=(ALL) SETENV: ALL"): en sudoers gana
///   la ultima regla que coincide, y esa pide contrasena para todo. Sin punto: sudo se salta esos archivos.
/// - SETENV ademas de NOPASSWD: brew siempre llama "sudo -E VAR=valor -- comando", y sin SETENV sudo lo
///   rechaza aunque no pida contrasena.
/// - El texto va compilado aqui y no se lee de la app: la app esta en una carpeta que el usuario puede
///   escribir, y el ayudante corre como root.
enum Regla {
    static var archivo = Raiz.regla
    /// Con punto: sudo no lo lee mientras se escribe y se revisa
    static var temporal: String { (archivo as NSString).deletingLastPathComponent + "/.zz_actualizate.nuevo" }

    /// Nombre de `uid` si es una cuenta de administrador (grupo admin, 80): la regla da root sin
    /// contrasena, y una cuenta estandar nunca lo tuvo
    static func administrador(uid: uid_t) -> String? {
        guard uid != 0, let pw = getpwuid(uid), let usuario = String(validatingCString: pw.pointee.pw_name),
              usuario.range(of: "^[a-z_][a-z0-9_.-]*$", options: .regularExpression) != nil else { return nil }
        var grupos = [Int32](repeating: 0, count: 64)
        var cuantos = Int32(grupos.count)
        guard getgrouplist(pw.pointee.pw_name, Int32(bitPattern: pw.pointee.pw_gid), &grupos, &cuantos) == 0,
              grupos.prefix(Int(cuantos)).contains(80) else { return nil }
        return usuario
    }

    static func texto(usuario: String) -> String {
        #"""
        # Actualizate: sudo sin contrasena para los comandos de las actualizaciones. Lo instala y lo quita
        # el ayudante de la app (Ajustes > Actualizar sin contrasena); no lo edites a mano.

        # Paquetes .pkg, sus recibos y sus servicios (Office, OneDrive, AdGuard, Zoom, VS Code...)
        Cmnd_Alias ACTUALIZATE_PKG = /usr/sbin/installer, /usr/sbin/pkgutil, /bin/launchctl

        # Desinstalar la version anterior y mover apps que son de root (brew los usa con sudo solo si hace falta)
        Cmnd_Alias ACTUALIZATE_ARCHIVOS = /usr/bin/xargs, /bin/rm, /bin/rmdir, /bin/mkdir, /bin/cp, /bin/mv, \
                                          /bin/ln, /bin/ls, /bin/chmod, /usr/bin/chgrp, /usr/sbin/chown, \
                                          /usr/bin/touch, /usr/bin/xattr, /usr/bin/ditto

        # mas 7 se vuelve a lanzar con sudo para instalar; brew copia atributos con su Ruby al mover apps de
        # root. Con * para que sigan valiendo cuando se actualicen
        Cmnd_Alias ACTUALIZATE_HOMEBREW = /opt/homebrew/Cellar/mas/*/libexec/bin/mas, \
                                          /opt/homebrew/Library/Homebrew/vendor/portable-ruby/*/bin/ruby

        \#(usuario) ALL = (root) NOPASSWD:SETENV: ACTUALIZATE_PKG, ACTUALIZATE_ARCHIVOS, ACTUALIZATE_HOMEBREW

        """#
    }

    /// Escribe la regla para `usuario` (ya comprobado con `administrador`); devuelve el error o nil
    static func instalar(usuario: String) -> String? {
        let datos = Data(texto(usuario: usuario).utf8)
        if let actual = FileManager.default.contents(atPath: archivo), actual == datos { return nil }
        unlink(temporal)
        guard FileManager.default.createFile(atPath: temporal, contents: datos),
              chown(temporal, 0, 0) == 0, chmod(temporal, 0o440) == 0 else {
            unlink(temporal)
            return "No se pudo escribir \(temporal) (\(String(cString: strerror(errno))))."
        }
        // Un sudoers con errores puede dejar sudo inservible: se revisa antes de ponerlo en su sitio
        let visudo = Process()
        visudo.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
        visudo.arguments = ["-cqf", temporal]
        visudo.standardOutput = FileHandle.nullDevice
        visudo.standardError = FileHandle.nullDevice
        do {
            try visudo.run()
            visudo.waitUntilExit()
        } catch {
            unlink(temporal)
            return "No se pudo revisar la regla con visudo: \(error.localizedDescription)"
        }
        guard visudo.terminationStatus == 0 else {
            unlink(temporal)
            return "visudo rechazó la regla; no se instaló."
        }
        guard rename(temporal, archivo) == 0 else {
            unlink(temporal)
            return "No se pudo instalar \(archivo) (\(String(cString: strerror(errno))))."
        }
        return nil
    }

    static func quitar() -> String? {
        unlink(temporal)
        guard unlink(archivo) == 0 || errno == ENOENT else {
            return "No se pudo borrar \(archivo) (\(String(cString: strerror(errno))))."
        }
        return nil
    }
}
