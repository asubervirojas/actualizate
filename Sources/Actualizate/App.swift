import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct ActualizateApp: App {
    @NSApplicationDelegateAdaptor(Delegado.self) private var delegado
    @StateObject private var c = Controlador.compartido
    @AppStorage("mostrarEnBarra") private var mostrarEnBarra = true
    @AppStorage("ocultarDock") private var ocultarDock = false

    var body: some Scene {
        Window("Actualizate", id: "principal") {
            VistaPrincipal()
                .environmentObject(c)
        }
        .defaultSize(width: 760, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Actualizaciones") {
                Button("Revisar") { c.revisar() }
                    .keyboardShortcut("r")
                    .disabled(c.corriendo)
                Button("Actualizar seleccionadas") { c.instalarSeleccion() }
                    .keyboardShortcut("u")
                    .disabled(c.corriendo || c.totalElegidos == 0)
                Button("Actualizar todo") { c.instalarTodo() }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                    .disabled(c.corriendo)
                Divider()
                Button("Apps instaladas…") { c.abrirAdoptar() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(!c.puedeAdoptar)
                Divider()
                Button("Cancelar") { c.cancelar() }
                    .keyboardShortcut(".")
                    .disabled(!c.corriendo)
            }
        }

        Settings {
            VistaAjustes()
                .environmentObject(c)
        }

        // Sin icono en el Dock la barra de menus es la unica entrada: no se puede quitar
        MenuBarExtra(isInserted: Binding(get: { mostrarEnBarra || ocultarDock }, set: { mostrarEnBarra = $0 })) {
            PanelBarra()
                .environmentObject(c)
        } label: {
            let n = c.totalPendientes
            Image(systemName: c.corriendo ? "arrow.triangle.2.circlepath" : (n > 0 ? "arrow.down.circle.fill" : "checkmark.circle"))
            if n > 0 { Text("\(n)") }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Icono en el Dock (app normal) o solo en la barra de menus (app accesoria)
@MainActor
enum Dock {
    static var ocultar: Bool { UserDefaults.standard.bool(forKey: "ocultarDock") }

    static func aplicar(activar: Bool) {
        // Sin Dock la barra de menus tiene que quedar puesta aunque antes se hubiera quitado
        if ocultar { UserDefaults.standard.set(true, forKey: "mostrarEnBarra") }
        NSApp.setActivationPolicy(ocultar ? .accessory : .regular)
        // Al cambiar de politica la app puede quedar detras de las demas o sin menus
        if activar { NSApp.activate() }
    }
}

final class Delegado: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Info.plist arranca sin Dock (LSUIElement) para que no parpadee el icono si se oculta
        Dock.aplicar(activar: false)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil {
            let centro = UNUserNotificationCenter.current()
            centro.delegate = self
            centro.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
        let defaults = UserDefaults.standard
        renovarInicioDeSesion(defaults)
        // Con el ayudante aprobado, la regla de sudo se pone al dia con la de esta version
        MainActor.assumeIsolated { SinContrasena.compartido.comprobar() }
        // open -a Actualizate --args --apps: abre directo en "Apps instaladas" (sin revisar al abrir,
        // que bloquearia la hoja mientras corre)
        if CommandLine.arguments.contains("--apps") {
            // SwiftUI termina de crear la escena después de este aviso. Con LSUIElement puede
            // existir la ventana pero seguir oculta, incluso cuando `open` ya lanzó el proceso.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NSApp.windows.first { $0.title == "Actualizate" }?.makeKeyAndOrderFront(nil)
                    NSApp.activate()
                    Controlador.compartido.abrirAdoptar()
                }
            }
        } else if defaults.object(forKey: "revisarAlAbrir") as? Bool ?? true {
            MainActor.assumeIsolated { Controlador.compartido.revisar() }
        }
    }

    /// El registro de abrir al iniciar sesion guarda la ruta de la app: tras moverla o cambiarle el nombre
    /// (antes Actualizar.app) apunta a una que ya no existe. Si estaba activo se rehace con esta copia, una vez
    private func renovarInicioDeSesion(_ defaults: UserDefaults) {
        let ruta = Bundle.main.bundlePath
        guard SMAppService.mainApp.status == .enabled, defaults.string(forKey: "inicioRegistradoEn") != ruta else { return }
        do {
            try SMAppService.mainApp.unregister()
            try SMAppService.mainApp.register()
            defaults.set(ruta, forKey: "inicioRegistradoEn")
        } catch {
            NSLog("No se pudo renovar el inicio de sesión: \(error.localizedDescription)")
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let c = MainActor.assumeIsolated { Controlador.compartido }
        let instalando = MainActor.assumeIsolated { c.modo == .instalar || c.modo == .adoptar }
        if instalando {
            let alerta = NSAlert()
            alerta.messageText = "Hay una actualización en curso"
            alerta.informativeText = "Si sales ahora se interrumpe a la mitad (brew y los instaladores lo toleran, pero puede quedar algo sin actualizar)."
            alerta.addButton(withTitle: "Seguir actualizando")
            alerta.addButton(withTitle: "Salir igual")
            if alerta.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        MainActor.assumeIsolated { c.terminarAlSalir() }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(Dock.ocultar || UserDefaults.standard.object(forKey: "mostrarEnBarra") as? Bool ?? true)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
