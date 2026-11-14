// Comprueba una firma EdDSA (ed25519) de Sparkle: sale con 0 si la firma del archivo es valida.
// Lo usa sparkle-pendientes antes de instalar un .pkg. Compilar:
//   swiftc -O ayudantes/ed25519-verify.swift -o ~/.local/bin/ed25519-verify
import CryptoKit
import Foundation

let argumentos = CommandLine.arguments
guard argumentos.count == 4 else {
    FileHandle.standardError.write(Data("uso: ed25519-verify <llave publica b64> <firma b64> <archivo>\n".utf8))
    exit(2)
}
guard let llave = Data(base64Encoded: argumentos[1]), let firma = Data(base64Encoded: argumentos[2]) else {
    FileHandle.standardError.write(Data("ed25519-verify: la llave o la firma no son base64\n".utf8))
    exit(2)
}
guard let publica = try? Curve25519.Signing.PublicKey(rawRepresentation: llave),
      let datos = try? Data(contentsOf: URL(fileURLWithPath: argumentos[3]), options: .alwaysMapped) else {
    exit(1)
}
exit(publica.isValidSignature(firma, for: datos) ? 0 : 1)
