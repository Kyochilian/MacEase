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
