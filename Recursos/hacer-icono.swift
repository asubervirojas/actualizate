// Genera las capas del icono de Icon Composer (Recursos/Actualizate.icon/Assets): un anillo con flecha
// detras y una flecha hacia arriba delante, en blanco sobre transparente. El fondo, el cristal y las
// variantes clara, oscura y tintada las pone icon.json.
// Uso: swift hacer-icono.swift <carpeta Assets>
import AppKit

let destino = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)

/// Simbolo centrado en un lienzo de 1024 con su lado mayor de `lado` px
func capa(_ nombre: String, lado: CGFloat, peso: NSFont.Weight, desplazamiento: CGPoint = .zero) -> Data {
    let s: CGFloat = 1024
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(s), pixelsHigh: Int(s), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let config = NSImage.SymbolConfiguration(pointSize: 100, weight: peso).applying(.init(paletteColors: [.white]))
    let simbolo = NSImage(systemSymbolName: nombre, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let escala = lado / max(simbolo.size.width, simbolo.size.height)
    let t = NSSize(width: simbolo.size.width * escala, height: simbolo.size.height * escala)
    simbolo.draw(in: NSRect(x: (s - t.width) / 2 + desplazamiento.x, y: (s - t.height) / 2 + desplazamiento.y,
                            width: t.width, height: t.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try capa("arrow.trianglehead.clockwise", lado: 600, peso: .semibold).write(to: destino.appendingPathComponent("anillo.png"))
try capa("arrow.up", lado: 230, peso: .heavy, desplazamiento: CGPoint(x: 0, y: -30)).write(to: destino.appendingPathComponent("flecha.png"))
