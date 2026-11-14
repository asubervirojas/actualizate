import AppKit
import ServiceManagement
import SwiftUI

// MARK: Estado para mostrar

extension Controlador {
    var tono: Color {
        if corriendo { return .accentColor }
        guard let r = resultado else { return totalPendientes > 0 ? .accentColor : .blue }
        if r.cancelado { return .orange }
        if totalPendientes > 0 { return .accentColor }
        return r.errores.isEmpty ? .green : .orange
    }

    var simboloEstado: String {
        if esperandoAutorizacion { return "touchid" }
        if corriendo { return "arrow.triangle.2.circlepath" }
        guard let r = resultado else { return totalPendientes > 0 ? "arrow.down.circle" : "arrow.triangle.2.circlepath" }
        if r.cancelado { return "stop.circle" }
        if totalPendientes > 0 { return "arrow.down.circle" }
        return r.errores.isEmpty ? "checkmark.seal" : "exclamationmark.triangle"
    }

    var tituloEstado: String {
        if modo == .adoptables { return "Buscando apps instaladas" }
        if modo == .adoptar { return "Adoptando apps" }
        if modo == .revisar { return "Revisando" }
        if modo == .instalar { return esperandoAutorizacion ? "Esperando autorización" : "Actualizando" }
        guard let r = resultado else {
            return totalPendientes > 0 ? Controlador.textoPendientes(totalPendientes) : "Buscar actualizaciones"
        }
        if r.cancelado { return "Cancelado" }
        if totalPendientes > 0 { return Controlador.textoPendientes(totalPendientes) }
        if !r.errores.isEmpty { return r.modo == .revisar ? "Revisión con problemas" : "Terminó con errores" }
        if microsoftPausado { return "Fuentes revisadas al día" }
        return r.modo == .revisar ? "Todo al día" : "Todo actualizado"
    }

    /// Texto bajo el titulo; `ahora` viene de un TimelineView para que "hace 5 min" se mantenga al dia
    func subtituloEstado(ahora: Date) -> String {
        if modo == .adoptables { return "Consultando su estado en Homebrew" }
        if modo == .adoptar { return "Instalando y verificando la copia de Homebrew" }
        if modo == .revisar {
            let listas = etapas.filter { !$0.estado.enCurso && $0.estado != .sinRevisar }.count
            return "\(listas) de \(etapas.count) fuentes listas"
        }
        if modo == .instalar {
            if esperandoAutorizacion { return "Usa Touch ID o escribe tu contraseña" }
            if let id = etapaActual, let e = etapas.first(where: { $0.id == id }) { return e.def.titulo }
            return "Preparando…"
        }
        var partes: [String] = []
        if let r = resultado, r.cancelado {
            partes.append("Se interrumpió a la mitad")
        } else if let fecha = ultimaRevision {
            let formato = RelativeDateTimeFormatter()
            formato.dateTimeStyle = .named
            partes.append("Revisado \(formato.localizedString(for: min(fecha, ahora), relativeTo: ahora))")
        } else {
            partes.append("Homebrew, App Store, Sparkle, Microsoft y macOS")
        }
        if let r = resultado, !r.errores.isEmpty {
            partes.append("problemas en \(r.errores.joined(separator: ", "))")
        }
        if microsoftPausado { partes.append("Microsoft AutoUpdate en pausa") }
        return partes.joined(separator: " · ")
    }

    /// Lo ultimo que escribio el proceso: la linea a medias (barras de descarga, preguntas) o la ultima completa
    var lineaViva: String {
        let parcial = lineaParcial.trimmingCharacters(in: .whitespaces)
        return parcial.isEmpty ? ultimaLinea : parcial
    }

    static func textoPendientes(_ n: Int) -> String {
        n == 1 ? "1 actualización" : "\(n) actualizaciones"
    }

    /// Secciones que piden atencion (tarjetas), en el orden del motor para que no salten; el resto va en fichas
    var etapasConNovedades: [EtapaEstado] {
        etapas.filter { !$0.items.isEmpty || $0.estado == .error || $0.estado == .instalando }
    }

    var etapasSinNovedades: [EtapaEstado] {
        let conNovedades = Set(etapasConNovedades.map(\.id))
        return etapas.filter { !conNovedades.contains($0.id) }
    }
}

// MARK: Ventana principal

struct VistaPrincipal: View {
    @EnvironmentObject var c: Controlador
    @AppStorage("mostrarRegistro") private var mostrarRegistro = false
    @AppStorage("betas") private var betas = false
    @Environment(\.openSettings) private var abrirAjustes
    @Environment(\.openWindow) private var abrirVentana

    var body: some View {
        let tarjetas = c.etapasConNovedades
        let fichas = c.etapasSinNovedades
        ScrollView {
            VStack(spacing: 26) {
                Encabezado()
                if !tarjetas.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(tarjetas) { etapa in
                            TarjetaSeccion(etapa: etapa)
                                .transition(.blurReplace)
                        }
                    }
                }
                if !fichas.isEmpty {
                    VStack(spacing: 10) {
                        let todasListas = fichas.allSatisfy { $0.estado == .alDia || $0.estado == .hecho }
                        Text(!tarjetas.isEmpty && todasListas ? "Sin novedades" : "Fuentes")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        FichasEstado(etapas: fichas)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 28)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            .animation(.smooth(duration: 0.35), value: tarjetas.map(\.id))
        }
        // Sin tarjetas, el estado queda centrado en vez de pegado arriba
        .defaultScrollAnchor(tarjetas.isEmpty ? .center : .top, for: .alignment)
        .frame(minWidth: 520)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background { FondoVentana(color: c.tono) }
        .inspector(isPresented: $mostrarRegistro) {
            PanelRegistro()
                .inspectorColumnWidth(min: 300, ideal: 380, max: 760)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if c.corriendo {
                    Button("Cancelar", systemImage: "stop.fill") { c.cancelar() }
                        .help("Interrumpir")
                } else {
                    Button("Revisar", systemImage: "arrow.clockwise") { c.revisar() }
                        .help("Revisar ahora")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation { mostrarRegistro.toggle() }
                } label: {
                    Label("Registro", systemImage: "terminal")
                }
                .help(mostrarRegistro ? "Ocultar el registro" : "Ver el registro de la terminal")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    c.abrirAdoptar()
                } label: {
                    Label("Apps instaladas", systemImage: "shippingbox.and.arrow.backward")
                }
                .disabled(!c.puedeAdoptar)
                .help("Apps instaladas y adopción en Homebrew")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    NSApp.activate()
                    abrirAjustes()
                } label: {
                    Label("Ajustes", systemImage: "gearshape")
                }
                .help("Ajustes de Actualizate")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Actualizar todo (como el comando de siempre)") { c.instalarTodo() }
                        .disabled(c.corriendo)
                    Toggle("Incluir betas de Sparkle", isOn: $betas)
                    Divider()
                    if let archivo = c.resultado?.archivo {
                        Button("Ver último registro") { NSWorkspace.shared.open(archivo) }
                    }
                    Button("Abrir carpeta de registros") { NSWorkspace.shared.open(Controlador.carpetaRegistros) }
                } label: {
                    Label("Más", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
            }
            if !c.corriendo, c.totalElegidos > 0 {
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        c.instalarSeleccion()
                    } label: {
                        Label("Actualizar \(c.totalElegidos)", systemImage: "arrow.down")
                            .labelStyle(.titleAndIcon)
                            .contentTransition(.numericText())
                    }
                    .buttonStyle(.glassProminent)
                    .help("Instalar lo marcado")
                }
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(isPresented: Binding(get: { c.pidiendoClave && !c.mostrandoAdoptar }, set: { c.pidiendoClave = $0 })) {
            HojaClave()
        }
        .sheet(isPresented: $c.mostrandoAdoptar) {
            HojaAdoptar()
        }
        .frame(minHeight: 540)
        .animation(.snappy, value: c.totalElegidos)
        .onAppear {
            c.actualizarInsignia()
            c.abrirPrincipal = {
                abrirVentana(id: "principal")
                NSApp.activate()
            }
        }
    }
}

/// Fondo con un degradado muy suave del color del estado: le da al cristal algo que refractar
struct FondoVentana: View {
    let color: Color

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            MeshGradient(
                width: 3, height: 3,
                points: [[0, 0], [0.5, 0], [1, 0],
                         [0, 0.45], [0.55, 0.38], [1, 0.5],
                         [0, 1], [0.5, 1], [1, 1]],
                colors: [color.opacity(0.30), color.opacity(0.16), Color.purple.opacity(0.16),
                         color.opacity(0.10), Color.clear, color.opacity(0.08),
                         Color.clear, Color.clear, Color.clear]
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: color)
    }
}

// MARK: Encabezado

struct Encabezado: View {
    @EnvironmentObject var c: Controlador

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: c.simboloEstado)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(c.tono)
                .symbolEffect(.rotate, isActive: c.corriendo && !c.esperandoAutorizacion)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 84, height: 84)
                .glassEffect(.regular.tint(c.tono.opacity(0.16)), in: .circle)

            VStack(spacing: 5) {
                Text(c.tituloEstado)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
                TimelineView(.periodic(from: .now, by: 30)) { contexto in
                    Text(c.subtituloEstado(ahora: contexto.date))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            if let r = c.resultado, !c.corriendo, !r.errores.isEmpty || r.cancelado, let archivo = r.archivo {
                Button("Ver registro") { NSWorkspace.shared.open(archivo) }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .animation(.smooth, value: c.corriendo)
        .animation(.smooth, value: c.esperandoAutorizacion)
    }
}

// MARK: Secciones con novedades

struct TarjetaSeccion: View {
    @EnvironmentObject var c: Controlador
    let etapa: EtapaEstado

    var body: some View {
        // 8 pt de margen y filas con 8 pt propios: todo alinea a 16 pt y el resaltado (12) es concentrico (20)
        VStack(alignment: .leading, spacing: 6) {
            cabecera
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)
            if !etapa.items.isEmpty {
                VStack(spacing: 0) {
                    ForEach(etapa.items) { item in
                        FilaItem(item: item, seleccion: etapa.def.seleccion)
                    }
                }
            }
            if let mensaje = etapa.mensaje, etapa.estado == .error || etapa.estado == .interrumpida {
                Label {
                    Text(mensaje).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption)
                .padding(.horizontal, 8)
            }
            ForEach(etapa.notas, id: \.self) { nota in
                Label(nota, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }

    private var cabecera: some View {
        HStack(spacing: 12) {
            Image(systemName: etapa.def.simbolo)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
                .background(.tint.opacity(0.14), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(etapa.def.titulo).font(.headline)
                if let subtitulo {
                    Text(subtitulo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            accesorio
        }
        .help(etapa.def.ayuda)
    }

    /// Solo lo que ayuda a decidir; los comandos quedan en el tooltip
    private var subtitulo: String? {
        switch etapa.estado {
        case .instalando: return "Actualizando…"
        case .revisando: return "Revisando…"
        default: return etapa.def.seleccion == .porItem ? nil : etapa.def.ayuda
        }
    }

    @ViewBuilder private var accesorio: some View {
        if etapa.estado.enCurso {
            ProgressView().controlSize(.small)
        } else if etapa.estado == .error && etapa.items.isEmpty {
            Label {
                Text("Error").foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .font(.caption.weight(.semibold))
        } else {
            switch etapa.def.seleccion {
            case .porItem where etapa.items.count > 1:
                let todas = etapa.items.allSatisfy { c.elegidos.contains($0.id) }
                Button(todas ? "Ninguna" : "Todas") {
                    withAnimation(.snappy) { c.elegirTodos(etapa, !todas) }
                }
                .buttonStyle(.borderless)
                .font(.callout)
                .disabled(c.corriendo)
            case .porEtapa:
                Toggle("Incluir \(etapa.def.titulo)", isOn: Binding(
                    get: { c.etapasElegidas.contains(etapa.id) },
                    set: { si in if si { c.etapasElegidas.insert(etapa.id) } else { c.etapasElegidas.remove(etapa.id) } }
                ).animation(.snappy))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(c.corriendo)
                .help("Incluir esta sección al actualizar")
            case .manual:
                Label {
                    Text(etapa.items.count == 1 ? "A mano" : "\(etapa.items.count) a mano").foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                }
                .font(.caption.weight(.semibold))
            default:
                EmptyView()
            }
        }
    }
}

struct FilaItem: View {
    @EnvironmentObject var c: Controlador
    let item: Item
    let seleccion: Seleccion
    @State private var encima = false

    private var elegible: Bool { seleccion == .porItem }
    private var elegido: Bool { c.elegidos.contains(item.id) }

    var body: some View {
        HStack(spacing: 12) {
            if elegible {
                Image(systemName: elegido ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(elegido ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
            IconoApp(item: item, lado: 32)
                .accessibilityHidden(true)
            Text(item.nombre)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
                .help(item.nombre)
            Spacer(minLength: 12)
            if c.modo == .instalar, let avance = c.avances[item.id] {
                BarraAvance(avance: avance)
                    .transition(.opacity)
            } else {
                HStack(spacing: 6) {
                    if !item.actual.isEmpty {
                        Text(item.actual)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(item.nueva)
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.tint.opacity(0.14), in: .capsule)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 190, alignment: .trailing)
            }
            if let url = item.url, let destino = URL(string: url) {
                Button(item.etapa == "macos" ? "Abrir Ajustes" : "Descargar") {
                    NSWorkspace.shared.open(destino)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(encima && elegible && !c.corriendo ? AnyShapeStyle(.primary.opacity(0.06)) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 12))
        .contentShape(.rect(cornerRadius: 12))
        .opacity(elegible && !elegido ? 0.8 : 1)
        .onHover { encima = $0 }
        .onTapGesture(perform: alternar)
        .animation(.smooth, value: c.modo == .instalar)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(elegible ? .isButton : [])
        .accessibilityValue(elegible ? (elegido ? "Marcada" : "Sin marcar") : "")
        .accessibilityAction { alternar() }
    }

    private func alternar() {
        guard elegible, !c.corriendo else { return }
        withAnimation(.snappy) {
            if elegido { c.elegidos.remove(item.id) } else { c.elegidos.insert(item.id) }
        }
    }
}

/// Barra fina al lado de cada app mientras se actualiza: vacia en cola, animada mientras no se sabe
/// cuanto falta, llena en verde al terminar
struct BarraAvance: View {
    let avance: Avance
    var ancho: CGFloat = 150

    var body: some View {
        HStack(spacing: 6) {
            // Dibujada a mano: la de AppKit se vuelve gris con la ventana en segundo plano
            Capsule()
                .fill(.primary.opacity(0.1))
                .overlay(alignment: .leading) { relleno }
                .clipShape(.capsule)
                .frame(width: ancho, height: 5)
            // Hueco fijo: la barra no se mueve cuando aparece el simbolo
            Group {
                switch avance.fase {
                case .hecho: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .error: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                default: Color.clear
                }
            }
            .font(.callout)
            .frame(width: 16, height: 16)
            .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(descripcion)
    }

    @ViewBuilder private var relleno: some View {
        if avance.fase == .trabajando && avance.fraccion == nil {
            // Sin dato de cuanto falta: un tramo que recorre la barra
            TimelineView(.animation(minimumInterval: 1 / 30)) { contexto in
                let fase = contexto.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                Capsule()
                    .fill(color)
                    .frame(width: ancho * 0.3)
                    .offset(x: (fase * 1.3 - 0.3) * ancho)
            }
        } else if let fraccion = avance.fraccion, fraccion > 0 {
            Capsule()
                .fill(color)
                .frame(width: max(ancho * min(fraccion, 1), 5))
                .animation(.smooth, value: fraccion)
        }
    }

    private var color: Color {
        switch avance.fase {
        case .hecho: .green
        case .error: .orange
        default: .accentColor
        }
    }

    private var descripcion: String {
        switch avance.fase {
        case .enCola: "En cola"
        case .trabajando: avance.fraccion.map { "Actualizando, \(Int($0 * 100)) %" } ?? "Actualizando"
        case .hecho: "Actualizada"
        case .error: "Con error"
        }
    }
}

struct IconoApp: View {
    let item: Item
    var lado: CGFloat = 32

    var body: some View {
        if let imagen = IconosApps.icono(item) {
            Image(nsImage: imagen)
                .resizable()
                .interpolation(.high)
                .frame(width: lado, height: lado)
        } else {
            // Misma reticula que los iconos de macOS: 80 % del lienzo y esquina de 18 %
            Image(systemName: IconosApps.simbolo(item))
                .font(.system(size: lado * 0.38, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: lado * 0.8, height: lado * 0.8)
                .background(.quaternary, in: .rect(cornerRadius: lado * 0.18))
                .frame(width: lado, height: lado)
        }
    }
}

// MARK: Fichas de lo que no tiene novedades

struct FichasEstado: View {
    let etapas: [EtapaEstado]

    var body: some View {
        FlujoCentrado(espacio: 8) {
            ForEach(etapas) { etapa in
                FichaEtapa(etapa: etapa)
            }
        }
    }
}

struct FichaEtapa: View {
    let etapa: EtapaEstado
    @State private var verNotas = false

    var body: some View {
        HStack(spacing: 6) {
            indicador
            Text(etapa.estado == .pausada ? "\(etapa.def.corto) en pausa" : etapa.def.corto).font(.callout)
            if !etapa.notas.isEmpty {
                Image(systemName: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        .help(ayuda)
        .onTapGesture { if !etapa.notas.isEmpty { verNotas = true } }
        .popover(isPresented: $verNotas) {
            VStack(alignment: .leading, spacing: 6) {
                Text(etapa.def.titulo).font(.headline)
                ForEach(etapa.notas, id: \.self) { nota in
                    Text(nota).font(.callout).textSelection(.enabled)
                }
            }
            .padding(14)
            .frame(maxWidth: 320, alignment: .leading)
        }
    }

    @ViewBuilder private var indicador: some View {
        switch etapa.estado {
        case .revisando, .instalando:
            ProgressView().controlSize(.mini)
        case .alDia:
            Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
        case .hecho:
            Image(systemName: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
        case .pausada:
            Image(systemName: "pause.circle").font(.caption).foregroundStyle(.secondary)
        case .interrumpida:
            Image(systemName: "stop.fill").font(.caption2).foregroundStyle(.orange)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        case .sinRevisar, .pendiente:
            Image(systemName: "circle.dotted").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var ayuda: String {
        var lineas = [etapa.def.titulo]
        switch etapa.estado {
        case .alDia: lineas.append("Al día")
        case .hecho: lineas.append(etapa.mensaje ?? "Actualizado")
        case .interrumpida: lineas.append(etapa.mensaje ?? "Interrumpida")
        case .sinRevisar: lineas.append("Sin revisar")
        case .pausada: lineas.append("En pausa; esta fuente no se ha revisado")
        default: break
        }
        return (lineas + etapa.notas).joined(separator: "\n")
    }
}

/// Acomoda las vistas en filas centradas que se parten segun el ancho disponible
struct FlujoCentrado: Layout {
    var espacio: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let filas = acomodar(ancho: proposal.width ?? .infinity, subviews)
        let ancho = filas.map(\.ancho).max() ?? 0
        let alto = filas.map(\.alto).reduce(0, +) + espacio * CGFloat(max(filas.count - 1, 0))
        return CGSize(width: proposal.width ?? ancho, height: alto)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for fila in acomodar(ancho: bounds.width, subviews) {
            var x = bounds.minX + (bounds.width - fila.ancho) / 2
            for (indice, tamano) in fila.vistas {
                subviews[indice].place(at: CGPoint(x: x, y: y + (fila.alto - tamano.height) / 2), proposal: ProposedViewSize(tamano))
                x += tamano.width + espacio
            }
            y += fila.alto + espacio
        }
    }

    private struct Fila {
        var vistas: [(Int, CGSize)] = []
        var ancho: CGFloat = 0
        var alto: CGFloat = 0
    }

    private func acomodar(ancho maximo: CGFloat, _ subviews: Subviews) -> [Fila] {
        var filas: [Fila] = []
        var actual = Fila()
        for (indice, vista) in subviews.enumerated() {
            let tamano = vista.sizeThatFits(.unspecified)
            let necesario = actual.vistas.isEmpty ? tamano.width : actual.ancho + espacio + tamano.width
            if necesario > maximo, !actual.vistas.isEmpty {
                filas.append(actual)
                actual = Fila()
            }
            actual.ancho = actual.vistas.isEmpty ? tamano.width : actual.ancho + espacio + tamano.width
            actual.alto = max(actual.alto, tamano.height)
            actual.vistas.append((indice, tamano))
        }
        if !actual.vistas.isEmpty { filas.append(actual) }
        return filas
    }
}

// MARK: Contrasena

struct HojaClave: View {
    @EnvironmentObject var c: Controlador
    @ObservedObject private var sin = SinContrasena.compartido
    @State private var clave = ""
    @State private var confirmarSinContrasena = false
    @FocusState private var enfocado: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .glassEffect(.regular.tint(Color.accentColor.opacity(0.15)), in: .circle)
            VStack(spacing: 6) {
                Text("Contraseña de macOS").font(.title3.weight(.semibold))
                Text("sudo la pide para instalar. Va directo al proceso y no se guarda.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if c.claveIncorrecta {
                Label("Contraseña incorrecta, intenta de nuevo", systemImage: "xmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            SecureField("Contraseña", text: $clave)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(width: 280)
                .focused($enfocado)
                .onSubmit(enviar)
            HStack(spacing: 10) {
                Button("Cancelar", role: .cancel) {
                    clave = ""
                    c.cancelarClave()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.glass)
                Button("Continuar", action: enviar)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(clave.isEmpty)
            }
            .controlSize(.large)
            if !c.textoClave.isEmpty {
                Text(c.textoClave).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            switch sin.estado {
            case .inactivo:
                Button("No volver a pedirla…") { confirmarSinContrasena = true }
                    .buttonStyle(.link)
                    .font(.callout)
            case .activo:
                // La sudo que ya espera no se entera: esta vez hay que contestarla o cancelar
                Text("Listo. Esta vez escribe la contraseña, o cancela y vuelve a actualizar.")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .multilineTextAlignment(.center)
            case .noDisponible:
                EmptyView()
            default:
                Text(sin.estado.detalle)
                    .font(.caption)
                    .foregroundStyle(sin.estado.color)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(width: 380)
        .onAppear { enfocado = true }
        .alert(SinContrasena.pregunta, isPresented: $confirmarSinContrasena) {
            Button("Cancelar", role: .cancel) {}
            Button("Instalar") { sin.activar() }
        } message: {
            Text(SinContrasena.explicacion)
        }
    }

    private func enviar() {
        guard !clave.isEmpty else { return }
        c.enviarClave(clave)
        clave = ""
    }
}

// MARK: Registro

struct PanelRegistro: View {
    @EnvironmentObject var c: Controlador
    @State private var entrada = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("Registro").font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(c.registro.texto, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copiar todo el registro")
                Button {
                    NSWorkspace.shared.open(Controlador.carpetaRegistros)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Registros anteriores")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            ConsolaTexto(registro: c.registro)
            if c.corriendo {
                VStack(alignment: .leading, spacing: 6) {
                    if !c.lineaParcial.isEmpty {
                        Text(c.lineaParcial)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    HStack(spacing: 8) {
                        TextField("Responder al proceso (Enter envía)", text: $entrada)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .onSubmit {
                                c.enviar(entrada + "\n")
                                entrada = ""
                            }
                        Button("Ctrl-C") { c.cancelar() }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .help("Interrumpe el proceso")
                    }
                }
                .padding(12)
            }
        }
    }
}

struct ConsolaTexto: NSViewRepresentable {
    let registro: Registro

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        if let vista = scroll.documentView as? NSTextView {
            vista.isEditable = false
            vista.isSelectable = true
            vista.isRichText = false
            vista.drawsBackground = false
            vista.textContainerInset = NSSize(width: 12, height: 8)
            vista.font = Registro.fuente
            registro.vista = vista
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let vista = nsView.documentView as? NSTextView, registro.vista !== vista {
            registro.vista = vista
        }
    }
}

// MARK: Barra de menus

struct PanelBarra: View {
    @EnvironmentObject var c: Controlador
    @Environment(\.openWindow) private var abrirVentana
    @Environment(\.openSettings) private var abrirAjustes
    @AppStorage("ocultarDock") private var ocultarDock = false

    private let maximo = 6

    var body: some View {
        let pendientes = c.etapas.flatMap(\.items)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: c.simboloEstado)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(c.tono)
                    .symbolEffect(.rotate, isActive: c.corriendo && !c.esperandoAutorizacion)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.tint(c.tono.opacity(0.16)), in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.tituloEstado)
                        .font(.headline)
                        .contentTransition(.numericText())
                    TimelineView(.periodic(from: .now, by: 30)) { contexto in
                        Text(c.subtituloEstado(ahora: contexto.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    c.revisar()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .disabled(c.corriendo)
                .help("Revisar ahora")
            }

            if !pendientes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(pendientes.prefix(maximo)) { item in
                        HStack(spacing: 10) {
                            IconoApp(item: item, lado: 22)
                                .accessibilityHidden(true)
                            Text(item.nombre)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .layoutPriority(1)
                            Spacer(minLength: 8)
                            if c.modo == .instalar, let avance = c.avances[item.id] {
                                BarraAvance(avance: avance, ancho: 96)
                            } else {
                                Text(item.nueva)
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.tint.opacity(0.14), in: .capsule)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    if pendientes.count > maximo {
                        Text("y \(pendientes.count - maximo) más")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 32)
                            .padding(.top, 2)
                    }
                }
            }

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if c.pidiendoClave {
                        Button {
                            mostrarVentana()
                        } label: {
                            Label("Escribir contraseña…", systemImage: "lock.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                    } else if c.corriendo {
                        Button {
                            c.cancelar()
                        } label: {
                            Text("Cancelar").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                    } else if c.totalElegidos > 0 {
                        Button {
                            c.instalarSeleccion()
                            mostrarVentana()
                        } label: {
                            Text("Actualizar \(c.totalElegidos)")
                                .contentTransition(.numericText())
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    Button {
                        mostrarVentana()
                    } label: {
                        Text("Abrir").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                }
                .controlSize(.large)
            }

            HStack(spacing: 14) {
                Spacer()
                Button {
                    c.abrirAdoptar()
                    mostrarVentana()
                } label: {
                    Image(systemName: "shippingbox.and.arrow.backward")
                }
                .disabled(!c.puedeAdoptar)
                .help("Apps instaladas y adopción en Homebrew")
                Button {
                    NSApp.activate()
                    abrirAjustes()
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Ajustes")
                Menu {
                    Toggle("Ocultar del Dock", isOn: $ocultarDock)
                    Divider()
                    Button("Salir de Actualizate") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Más opciones")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 330)
        .animation(.smooth, value: pendientes.map(\.id))
        .animation(.smooth, value: c.corriendo)
        .animation(.smooth, value: c.esperandoAutorizacion)
        .animation(.snappy, value: c.totalElegidos)
        // Un Toggle dentro de un menu no es una vista viva: el cambio se aplica aqui
        .onChange(of: ocultarDock) { _, _ in Dock.aplicar(activar: false) }
        .onAppear {
            c.abrirPrincipal = {
                abrirVentana(id: "principal")
                NSApp.activate()
            }
        }
    }

    private func mostrarVentana() {
        abrirVentana(id: "principal")
        NSApp.activate()
    }
}

// MARK: Adoptar apps

/// Grupos de la hoja de apps instaladas, en este orden
enum SeccionApps: CaseIterable, Identifiable {
    case adoptar, homebrew, sinCask, appStore, apple

    var id: Self { self }

    var titulo: String {
        switch self {
        case .adoptar: "Para adoptar"
        case .homebrew: "Ya en Homebrew"
        case .sinCask: "Sin gestionar con Homebrew"
        case .appStore: "App Store"
        case .apple: "De Apple"
        }
    }

    var ayuda: String? {
        switch self {
        case .adoptar: "Quedará la copia de Homebrew. Tras verificarla, las copias anteriores se eliminan definitivamente, sin Papelera ni respaldo permanente. Tus datos y preferencias se conservan."
        case .sinCask: "Homebrew no puede adoptar estas copias tal como están: revisa su versión, ubicación o disponibilidad."
        default: nil
        }
    }

    func contiene(_ estado: Adoptable.Estado) -> Bool {
        switch self {
        case .adoptar: estado.adoptable
        case .homebrew: estado == .brew
        case .sinCask: estado == .sincask || estado == .deshabilitado || estado == .version
        case .appStore: estado == .mas
        case .apple: estado == .apple
        }
    }
}

struct HojaAdoptar: View {
    @EnvironmentObject var c: Controlador
    @Environment(\.dismiss) private var cerrar
    @State private var filtro = ""

    private var buscando: Bool { c.modo == .adoptables }

    private var visibles: [Adoptable] {
        let texto = filtro.trimmingCharacters(in: .whitespaces)
        let todas = c.adoptables.sorted { $0.nombre.localizedStandardCompare($1.nombre) == .orderedAscending }
        guard !texto.isEmpty else { return todas }
        return todas.filter { $0.nombre.localizedCaseInsensitiveContains(texto) || $0.token.localizedCaseInsensitiveContains(texto) }
    }

    var body: some View {
        VStack(spacing: 0) {
            cabecera
            if let error = c.errorInventario {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
            }
            if !c.adoptables.isEmpty { buscador }
            contenido
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if c.corriendo, !c.lineaViva.isEmpty {
                Text(c.lineaViva)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .transition(.opacity)
            }
            pie
        }
        .frame(width: 620, height: 680)
        .animation(.smooth, value: c.adoptables.map(\.id))
        .animation(.smooth, value: c.corriendo)
        .animation(.snappy, value: c.totalAdoptablesElegidos)
        // sudo puede pedir contrasena (casks con paquete): se pide desde aqui, encima de esta hoja
        .sheet(isPresented: $c.pidiendoClave) {
            HojaClave()
        }
        .onAppear {
            if !c.adoptablesBuscados && !c.corriendo { c.buscarAdoptables() }
        }
        // Si se abrio mientras corria otra cosa, busca en cuanto termine
        .onChange(of: c.corriendo) { _, ahora in
            let otraCosa = c.ultimoModoTerminado == .revisar || c.ultimoModoTerminado == .instalar
            if !ahora && otraCosa && !c.adoptablesBuscados { c.buscarAdoptables() }
        }
    }

    private var cabecera: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 52, height: 52)
                .glassEffect(.regular.tint(Color.accentColor.opacity(0.15)), in: .circle)
            VStack(alignment: .leading, spacing: 3) {
                Text("Apps instaladas").font(.title2.weight(.semibold))
                Text(resumen)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }

    private var resumen: String {
        if c.adoptables.isEmpty { return buscando ? "Buscando en Aplicaciones…" : "Todas las apps de la Mac y su estado en Homebrew" }
        let enBrew = c.adoptables.filter { $0.estado == .brew }.count
        let paraAdoptar = c.adoptables.filter { $0.estado.adoptable }.count
        return "\(c.adoptables.count) apps · \(enBrew) en Homebrew · \(paraAdoptar) para adoptar"
    }

    private var buscador: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Buscar app o cask", text: $filtro)
                .textFieldStyle(.plain)
            if !filtro.isEmpty {
                Button {
                    filtro = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Borrar búsqueda")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var contenido: some View {
        if c.adoptables.isEmpty && c.errorInventario != nil {
            Text("Pulsa «Volver a buscar» para completar el inventario.")
                .foregroundStyle(.secondary)
        } else if c.adoptables.isEmpty && (buscando || !c.adoptablesBuscados) {
            VStack(spacing: 12) {
                if buscando {
                    ProgressView()
                    Text("Revisando las apps de la Mac…")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Revisa qué apps de la Mac puede manejar Homebrew.")
                        .foregroundStyle(.secondary)
                    Button("Buscar", systemImage: "magnifyingglass") { c.buscarAdoptables() }
                        .buttonStyle(.glass)
                        .disabled(c.corriendo)
                }
            }
        } else if visibles.isEmpty {
            Text(filtro.isEmpty ? "No se encontraron apps." : "Ninguna app coincide con «\(filtro)».")
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(SeccionApps.allCases) { seccion in
                        let apps = visibles.filter { seccion.contiene($0.estado) }
                        // "Para adoptar" se muestra aunque este vacia, para que se entienda que no falta nada
                        if !apps.isEmpty || (seccion == .adoptar && filtro.isEmpty) {
                            SeccionAppsVista(seccion: seccion, apps: apps)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
        }
    }

    private var pie: some View {
        HStack(spacing: 10) {
            Button("Volver a buscar", systemImage: "arrow.clockwise") { c.buscarAdoptables() }
                .buttonStyle(.glass)
                .disabled(c.corriendo)
            Spacer()
            if c.corriendo {
                Button("Cancelar") { c.cancelar() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
            } else {
                Button("Cerrar") { cerrar() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.glass)
            }
            Button {
                c.adoptar()
            } label: {
                Text(c.totalAdoptablesElegidos > 0 ? "Adoptar \(c.totalAdoptablesElegidos)" : "Adoptar")
                    .contentTransition(.numericText())
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(c.corriendo || c.errorInventario != nil || c.totalAdoptablesElegidos == 0)
        }
        .controlSize(.large)
        .padding(20)
    }
}

struct SeccionAppsVista: View {
    @EnvironmentObject var c: Controlador
    let seccion: SeccionApps
    let apps: [Adoptable]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(seccion.titulo).font(.subheadline.weight(.semibold))
                Text("\(apps.count)").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if seccion == .adoptar && apps.count > 1 {
                    let todas = apps.allSatisfy { c.adoptablesElegidos.contains($0.id) }
                    Button(todas ? "Ninguna" : "Todas") {
                        withAnimation(.snappy) {
                            for app in apps {
                                if todas { c.adoptablesElegidos.remove(app.id) } else { c.adoptablesElegidos.insert(app.id) }
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .disabled(c.corriendo)
                }
            }
            .padding(.horizontal, 8)
            if let ayuda = seccion.ayuda {
                Text(ayuda)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            Group {
                if apps.isEmpty {
                    Label("No hay apps que puedan adoptarse ahora.", systemImage: "checkmark.seal")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                } else {
                    VStack(spacing: 0) {
                        ForEach(apps) { app in
                            FilaAdoptable(app: app, seleccionable: seccion == .adoptar)
                        }
                    }
                }
            }
            .padding(8)
            .background(.regularMaterial, in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
        }
    }
}

struct FilaAdoptable: View {
    @EnvironmentObject var c: Controlador
    let app: Adoptable
    let seleccionable: Bool
    @State private var encima = false

    // El fallo al retirar un duplicado no se atribuye a la copia que Homebrew ya gestiona.
    private var resultado: Bool? { app.token.isEmpty || app.estado == .brew ? nil : c.resultadosAdopcion[app.token] }
    private var elegible: Bool { seleccionable && app.estado.adoptable && resultado != true && c.errorInventario == nil }
    private var elegido: Bool { c.adoptablesElegidos.contains(app.id) }

    private var detalle: String {
        var partes: [String] = []
        if !app.instalada.isEmpty { partes.append(app.instalada) }
        if !app.token.isEmpty { partes.append("cask \(app.token)") }
        let carpeta = (app.ruta as NSString).deletingLastPathComponent
        if carpeta != "/Applications" { partes.append((carpeta as NSString).abbreviatingWithTildeInPath) }
        return partes.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            if seleccionable {
                indicador
                    .frame(width: 20)
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.ruta))
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.nombre)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if !detalle.isEmpty {
                    Text(detalle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            etiqueta
        }
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(encima && elegible && !c.corriendo ? AnyShapeStyle(.primary.opacity(0.06)) : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 12))
        .contentShape(.rect(cornerRadius: 12))
        .opacity(elegible && !elegido ? 0.8 : 1)
        .onHover { encima = $0 }
        .onTapGesture(perform: alternar)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(elegible ? .isButton : [])
        .accessibilityValue(elegible ? (elegido ? "Marcada" : "Sin marcar") : "")
        .accessibilityAction { alternar() }
    }

    @ViewBuilder private var indicador: some View {
        if c.modo == .adoptar && elegido && resultado == nil {
            ProgressView().controlSize(.small)
        } else if let resultado {
            Image(systemName: resultado ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.system(size: 18))
                .foregroundStyle(resultado ? .green : .orange)
        } else {
            Image(systemName: elegido ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 19))
                .foregroundStyle(elegido ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
        }
    }

    @ViewBuilder private var etiqueta: some View {
        if let resultado {
            Text(resultado ? "Adoptada" : "No se pudo")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .help(resultado ? "Ahora la maneja Homebrew" : "Revisa el registro para ver el error de brew")
        } else {
            switch app.estado {
            case .si:
                Text("Lista")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.tint.opacity(0.14), in: .capsule)
                    .help("Se instala y verifica la copia de Homebrew; después se elimina definitivamente la original")
            case .paquete:
                Label {
                    Text("Se reinstala").foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "lock.fill").foregroundStyle(.orange)
                }
                .font(.caption.weight(.semibold))
                .help("Este cask se instala con su paquete oficial (\(app.version)): Homebrew la reinstala encima y pide tu contraseña")
            case .version:
                Text("Cask \(app.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("El cask no permite reemplazar esta versión con seguridad; tienes \(app.instalada)")
            case .fuera:
                Text("Retirar original")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Se verifica la copia de Homebrew y después se elimina definitivamente esta original")
            case .deshabilitado:
                Text("Cask retirado")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Homebrew retiró este cask y ya no lo instala")
            case .brew, .mas, .apple, .sincask:
                EmptyView()
            }
        }
    }

    private func alternar() {
        guard elegible, !c.corriendo else { return }
        withAnimation(.snappy) {
            if elegido { c.adoptablesElegidos.remove(app.id) } else { c.adoptablesElegidos.insert(app.id) }
        }
    }
}

// MARK: Ajustes

struct VistaAjustes: View {
    @EnvironmentObject var c: Controlador
    @AppStorage("revisarAlAbrir") private var revisarAlAbrir = true
    @AppStorage("intervaloHoras") private var intervaloHoras = 12
    @AppStorage("mostrarEnBarra") private var mostrarEnBarra = true
    @AppStorage("ocultarDock") private var ocultarDock = false
    @AppStorage("notificar") private var notificar = true
    @AppStorage("betas") private var betas = false
    @State private var alIniciar = SMAppService.mainApp.status == .enabled
    @State private var errorInicio: String?

    var body: some View {
        Form {
            Section("Revisión") {
                Toggle("Revisar al abrir la app", isOn: $revisarAlAbrir)
                Picker("Revisar en segundo plano", selection: $intervaloHoras) {
                    Text("Nunca").tag(0)
                    Text("Cada 6 horas").tag(6)
                    Text("Cada 12 horas").tag(12)
                    Text("Cada día").tag(24)
                }
                Toggle("Incluir betas de Sparkle", isOn: $betas)
                Toggle(isOn: $c.microsoftPausado) {
                    Text("Pausar Microsoft AutoUpdate")
                    Text("Deja a Microsoft AutoUpdate fuera de Actualizate. Homebrew sigue revisando las apps que gestiona.")
                }
                .disabled(c.corriendo)
            }
            Section("App") {
                Toggle(isOn: $ocultarDock) {
                    Text("Solo en la barra de menús")
                    Text("Oculta el icono del Dock y de ⌘Tab. La ventana se abre desde el icono de la barra de menús.")
                }
                .onChange(of: ocultarDock) { _, _ in Dock.aplicar(activar: true) }
                Toggle("Mostrar en la barra de menús", isOn: Binding(get: { mostrarEnBarra || ocultarDock }, set: { mostrarEnBarra = $0 }))
                    .disabled(ocultarDock)
                    .help(ocultarDock ? "Sin icono en el Dock, la barra de menús es la única forma de abrir la app" : "")
                Toggle("Notificar al terminar", isOn: $notificar)
                Toggle("Abrir al iniciar sesión", isOn: $alIniciar)
                    .onChange(of: alIniciar) { _, si in
                        do {
                            if si { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            errorInicio = nil
                        } catch {
                            errorInicio = error.localizedDescription
                        }
                    }
                if let errorInicio {
                    Text(errorInicio).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Contraseña") {
                FilaSinContrasena()
            }
            Section("Comando de terminal") {
                Text("La app usa el motor `actualizar`, que también corre en la terminal:")
                    .font(.callout)
                Text(c.rutaMotor)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Text("actualizar revisar  ·  actualizar instalar --etapas formulas,casks  ·  actualizar --help")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Copiar ruta") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(c.rutaMotor, forType: .string)
                    }
                    Button("Abrir registros") { NSWorkspace.shared.open(Controlador.carpetaRegistros) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Ajustes > Contraseña: el ayudante root que deja actualizar sin contraseña
struct FilaSinContrasena: View {
    @ObservedObject private var sin = SinContrasena.compartido
    @State private var confirmar = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Actualizar sin contraseña")
                Text(sin.estado.detalle)
                    .font(.caption)
                    .foregroundStyle(sin.estado.color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            botones
        }
        .alert(SinContrasena.pregunta, isPresented: $confirmar) {
            Button("Cancelar", role: .cancel) {}
            Button("Instalar") { sin.activar() }
        } message: {
            Text(SinContrasena.explicacion)
        }
        .onAppear { sin.comprobar() }
    }

    @ViewBuilder private var botones: some View {
        switch sin.estado {
        case .inactivo:
            Button("Instalar…") { confirmar = true }
        case .noDisponible:
            EmptyView()
        case .esperandoAprobacion:
            Button("Cancelar") { sin.desactivar() }
            Button("Abrir Ajustes del Sistema") { sin.abrirAjustesDelSistema() }
        case .trabajando:
            ProgressView().controlSize(.small)
        case .activo, .reglaSuelta:
            Button("Quitar") { sin.desactivar() }
        case .error(_, quitando: true):
            Button("Reintentar quitar") { sin.desactivar() }
        case .error:
            Button("Quitar") { sin.desactivar() }
            Button("Reintentar") { sin.activar() }
        }
    }
}

extension SinContrasena.Estado {
    var detalle: String {
        switch self {
        case .inactivo: "Homebrew, App Store y los instaladores .pkg piden contraseña o Touch ID."
        case .noDisponible: "Esta copia de la app no trae el ayudante: se compiló sin una firma de Apple."
        case .esperandoAprobacion: "Actívalo en Ajustes del Sistema > General > Elementos de inicio y extensiones."
        case .trabajando: "Un momento…"
        case .activo: "Activo: las actualizaciones no piden contraseña."
        case .reglaSuelta: "La regla de sudo sigue puesta aunque el ayudante está apagado."
        case .error(let mensaje, _): mensaje
        }
    }

    var color: Color {
        switch self {
        case .activo: .green
        case .error, .reglaSuelta: .red
        default: .secondary
        }
    }
}
