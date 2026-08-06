import Foundation
import Testing

@testable import NeteaseKit

@Test func weapiGoldenVector() {
  let json = #"{"ids":"[347230]","level":"standard","encodeType":"aac"}"#
  let parameters = NeteaseCrypto.weapi(
    json: json,
    secretKey: "0123456789abcdef"
  )

  #expect(
    parameters.params
      == "5RzDOeVWxD8PGD5eX0lAWOWvbkyqyeonWnruQT///AlNK9LY6ZDKMkFI8UTik7e+PvjyKnjt5eBDOkrvwL/lqgS1ElxqXI9/YK+aT0YoB93GWp0C+0J3vtISS7iKYM5L"
  )
  #expect(
    parameters.encSecKey
      == "35701388baf89fed412e11269b9c76625d095ecaf17f03fa018abe19ea2d38b949debf242ee39a71ca1f6cda71b1b86a45aa909ee27f7e78e267d34e732f0de948206c3340a788d0003372183e2f753c1f78b66ac23d134ac1fc9b993156520ea826b8aa89a962d4491b4b8d7e08738e1da9b07aa39bf4a7ef0b1c210728cd52"
  )
}

@Test func eapiGoldenVector() {
  let path = "/api/song/enhance/player/url/v1"
  let json = #"{"ids":"[347230]","level":"standard","encodeType":"flac"}"#

  #expect(
    NeteaseCrypto.eapi(path: path, json: json)
      == "FA90B329E9614F79E79598F37DC2EDB487F00D1BC4C9B24CD57E6C318B9073569338432CD7D98D1A3626E997A2C53121C461EE0E88D3D1BF3F42E78643807A29B83D00D24CECA2C01F229A64E4D80CBB43B3579770BB9A18CB701D3B0BC6D06534152C48015A10B37D65EAF37AA55CDB865AFA2367A1328A406C1D0BFDFE0C5AE4BE39397EDC48F19815DE0CB86E1B30E15AEF43036BA0683F3F57B81CB4B5EE"
  )
}

@Test func eapiResponseVectors() {
  let plain = Data(
    base64Encoded: "yZRj59wuKJ/1c341BcjpjuTshRqno5xD/aCanv/ZfBo="
  )!
  #expect(
    String(
      decoding: NeteaseCrypto.decodeEAPIResponse(plain, gzipped: false),
      as: UTF8.self
    )
      == #"{"code":200,"profile":null}"#
  )

  let gzipped = Data(
    base64Encoded:
      "dXY/63Tzn9uSjnPxpGi/Pj5UlZPCzL8cO2ATIj+hkcGecJNNO0nZtDfDymN62s6baqOxAvvnKWqw256lxGrRKw=="
  )!
  #expect(
    String(
      decoding: NeteaseCrypto.decodeEAPIResponse(gzipped, gzipped: true),
      as: UTF8.self
    )
      == #"{"code":200,"data":["gzip"]}"#
  )
}

@Test func xeapiInitialRequestGoldenVector() {
  let parameters = NeteaseCrypto.xeapi(
    formBody: Data("ids=%5B347230%5D&level=standard&encodeType=flac".utf8),
    publicKey: Data(
      base64Encoded: "YFpyXSpK3+6xop4X7dYhwbdZPujNvESsbEq24vgF0jw="
    )!,
    version: "42",
    sk: "test-sk",
    os: "android",
    dynamicKey: Data("0123456789abcdef".utf8),
    transform: Data([
      0x0f, 0x0e, 0x0d, 0x0c, 0x0b, 0x0a, 0x09, 0x08,
      0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x00,
    ]),
    ephemeralPrivateKey: Data((0..<32).map { UInt8($0) }),
    nonce: Data((0..<12).map { UInt8($0) })
  )

  #expect(
    parameters.b
      == "d+IML8fW1RctiSw3Kf8qiJWmkiqd7ZUZG9z47EDIv2EjE7qpIy5okDyluMqo1aX5v5s6DZqVb51mRz/Ac85MndBI6+8n+vCaM2/4Mz3uUwq71Nnwv74vSrHOMFkRZJWpq7KHfrx94GgqCPwHa+CpOl9XV9nLi00ijfFNwhxMpSGVCOIq+wNXper+u+qyyuzou1F4mS8kfc0q2soQrd5FcbynmR9oNp1uBKVzSxfR4iQ="
  )
  #expect(
    parameters.s
      == "j0DFrbaPJWJK5bIU6nZ6bslNgp09e14a0bpvPiE4KF8AAQIDBAUGBwgJCguBbAubYU1YcRpJWMnkSsU5LmfHllfdwgGTd9U+vBhIA9g/ZlTuG/IoR299VCw/g7BylQZ7l0qrpQ=="
  )
  #expect(parameters.r == "MS2tK79o3GW1nNBiSHA6Vw==")
}

@Test func xeapiSessionReuseGoldenVector() {
  let parameters = NeteaseCrypto.xeapi(
    formBody: Data("ids=%5B347230%5D&level=standard&encodeType=flac".utf8),
    publicKey: Data(
      base64Encoded: "YFpyXSpK3+6xop4X7dYhwbdZPujNvESsbEq24vgF0jw="
    )!,
    version: "42",
    sk: "test-sk",
    os: "android",
    dynamicKey: Data("session-key-0001".utf8),
    transform: Data([
      0x0f, 0x0e, 0x0d, 0x0c, 0x0b, 0x0a, 0x09, 0x08,
      0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x00,
    ]),
    ephemeralPrivateKey: Data((32..<64).map { UInt8($0) }),
    nonce: Data((16..<28).map { UInt8($0) }),
    sessionID: "ssid-test-42"
  )

  #expect(
    parameters.b
      == "zqdQYZk+gzBbfcHaxGhkesCQ7N3JLpxYucLtF3VMjlyw/77Y3Xa+Ou01SKF1APcCVxOlmkJm7EJr2vZ/IFZpk25FlqmCLrCE8DFox6zaCJ/lvfeURTCwyGP9UCBu48AMzFQzJkaaaiTsVcQpzEjI5fsO1FLS9L2sohI32sFZvM9WIobzK1NLq0DYrFaqB7P4lYQkHEqnDN5Y75DphTzBvaWl9jEpgcP4sZ6o82WZJ9I="
  )
  #expect(
    parameters.s
      == "NYBy1jZYgNGu6jKa35EhODhR7SGijjt16WXQ0s0WYlQQERITFBUWFxgZGhs2An43hEiDrAfdERfHGwI7boc2oJ2ebovOnGI5w58/2NdhKujCbauJVryuC6qvj0adDmakGruqaQ=="
  )
  #expect(parameters.r == "FFQImDvaR6cq8m+upjxY1Q==")
}

@Test func xeapiKeySignatureGoldenVector() {
  #expect(
    NeteaseCrypto.xeapiKeySignature(
      timestamp: "1722945678123",
      nonce: "0123456789012345"
    ) == "9OL4vPcD4GHBd1JVhu9RcB37HlCfZ1Zc2ltR5o8r6H8="
  )
}

@Test func xeapiPublicKeyStateGoldenVector() {
  let state = NeteaseCrypto.decodeXeAPIPublicKeyState(
    Data(
      base64Encoded:
        "GhuOQkj9H8Qa6IXvAf/36MDK6hIpjJgvdZpYr/xQwcKGBtl8KwDC/h+VmkACqd+fN8lKKBP98O6/K3861uVw52zAsj9wmkoUKA7yK8So2K1aM0ZJAJf7T7vl/ndevWBF"
    )!
  )

  #expect(
    state.publicKey
      == Data(base64Encoded: "YFpyXSpK3+6xop4X7dYhwbdZPujNvESsbEq24vgF0jw=")!
  )
  #expect(state.version == "42")
  #expect(state.sk == "test-sk")
}
