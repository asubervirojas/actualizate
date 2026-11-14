import CPty
import Foundation

/// Un proceso corriendo en su propia pseudo terminal. La salida y el fin llegan en el hilo principal.
final class ProcesoPTY {
    var alRecibir: ((Data) -> Void)?
    var alTerminar: ((Int32) -> Void)?

    private(set) var pid: pid_t = 0
    // Solo se tocan en `cola`
    private var maestro: Int32 = -1
    private var abierto = false
    private var lectura: DispatchSourceRead?
    private let cola = DispatchQueue(label: "actualizar.pty")

    struct ErrorInicio: LocalizedError {
        let errorDescription: String?
    }

    func iniciar(ejecutable: String, argumentos: [String], entorno: [String: String],
                 directorio: String? = nil, columnas: UInt16 = 120, filas: UInt16 = 40) throws {
        let argv = ([ejecutable] + argumentos).map { strdup($0) } + [nil]
        let envp = entorno.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var fd: Int32 = -1
        let p = argv.withUnsafeBufferPointer { a in
            envp.withUnsafeBufferPointer { e in
                cpty_spawn(ejecutable, a.baseAddress, e.baseAddress, directorio, columnas, filas, &fd)
            }
        }
        guard p > 0, fd >= 0 else {
            throw ErrorInicio(errorDescription: "No se pudo crear la terminal (\(String(cString: strerror(errno))))")
        }
        pid = p
        cola.sync {
            maestro = fd
            abierto = true
            let fuente = DispatchSource.makeReadSource(fileDescriptor: fd, queue: cola)
            fuente.setEventHandler { [weak self] in self?.leerDisponible() }
            fuente.setCancelHandler { close(fd) }
            fuente.resume()
            lectura = fuente
        }

        // waitpid en un hilo propio: no depende de registrar el proceso antes de que termine
        Thread.detachNewThread { [weak self] in
            var estado: Int32 = 0
            while waitpid(p, &estado, 0) < 0 && errno == EINTR {}
            let codigo: Int32 = (estado & 0x7f) == 0 ? (estado >> 8) & 0xff : 128 + (estado & 0x7f)
            self?.cola.async { self?.finalizar(codigo) }
        }
    }

    func escribir(_ texto: String) {
        let bytes = Array(texto.utf8)
        cola.async { [weak self] in
            guard let self, self.abierto else { return }
            var enviados = 0
            var intentos = 0
            while enviados < bytes.count && intentos < 500 {
                let n = bytes.withUnsafeBytes { write(self.maestro, $0.baseAddress! + enviados, bytes.count - enviados) }
                if n > 0 {
                    enviados += n
                } else if errno == EAGAIN || errno == EINTR {
                    intentos += 1
                    usleep(2000)
                } else {
                    break
                }
            }
        }
    }

    /// Ctrl-C a traves de la terminal: llega a todo el grupo de procesos en primer plano
    func interrumpir() { escribir("\u{03}") }

    func terminar() {
        guard pid > 0 else { return }
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
    }

    func cambiarTamano(columnas: UInt16, filas: UInt16) {
        cola.async { [weak self] in
            guard let self, self.abierto else { return }
            _ = cpty_resize(self.maestro, columnas, filas)
        }
    }

    private func leerDisponible() {
        guard abierto else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        var datos = Data()
        while datos.count < 1 << 20 {
            let n = read(maestro, &buffer, buffer.count)
            if n > 0 {
                datos.append(buffer, count: n)
            } else {
                // EAGAIN: no hay mas por ahora. 0 o EIO: ya nadie tiene abierto el lado esclavo
                if n == 0 || (errno != EAGAIN && errno != EINTR) { cerrar() }
                break
            }
        }
        if !datos.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.alRecibir?(datos) }
        }
    }

    private func cerrar() {
        guard abierto else { return }
        abierto = false
        maestro = -1
        lectura?.cancel()
        lectura = nil
    }

    private func finalizar(_ codigo: Int32) {
        // Lo que quedo en la terminal cuando el proceso salio; cerrar el maestro manda SIGHUP a lo
        // que siga vivo en la sesion
        leerDisponible()
        cerrar()
        DispatchQueue.main.async { [weak self] in self?.alTerminar?(codigo) }
    }
}
