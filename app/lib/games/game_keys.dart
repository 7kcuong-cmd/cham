/// Khoá công khai Ed25519 (base64) để kiểm chữ ký game. Tạo bằng `cham-game-pack keygen`,
/// dán nội dung tệp `.pub` vào đây. Để trống = app từ chối mọi game tải về (an toàn mặc định).
///
/// ĐANG DÙNG KHOÁ THỬ NGHIỆM (khoá bí mật nằm ở phiên làm việc tạo ra nó, không nên tin cho bản phát hành).
/// Trước khi phát hành: chạy `cham-game-pack keygen` trên máy của bạn, thay dòng dưới, ký lại các game.
const String kGamePublicKeyB64 = '5G2EzgkVzoisdRSOrOiJcVJmDyDG4DYvq5/OBclywyA=';
