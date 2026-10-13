/// Danh mục nhóm/sở thích (mã gửi lên server là `id`, nhãn hiển thị theo ngôn ngữ).
/// Server chỉ kiểm dạng mã (`^[a-z0-9_]{2,24}$`, tối đa [kMaxInterests]) nên thêm mục mới KHÔNG cần sửa server.
const int kMaxInterests = 12;

class InterestItem {
  const InterestItem(this.id, this.vi, this.en);
  final String id;
  final String vi;
  final String en;

  String label(String lang) => lang == 'vi' ? vi : en;
}

class InterestGroup {
  const InterestGroup(this.id, this.vi, this.en, this.items);
  final String id;
  final String vi;
  final String en;
  final List<InterestItem> items;

  String title(String lang) => lang == 'vi' ? vi : en;
}

const List<InterestGroup> kInterestGroups = <InterestGroup>[
  InterestGroup('art', 'Nghệ thuật', 'Arts', <InterestItem>[
    InterestItem('music', 'Âm nhạc', 'Music'),
    InterestItem('singing', 'Ca hát', 'Singing'),
    InterestItem('painting', 'Hội họa', 'Painting'),
    InterestItem('photography', 'Nhiếp ảnh', 'Photography'),
    InterestItem('dance', 'Nhảy múa', 'Dance'),
    InterestItem('film', 'Điện ảnh', 'Film'),
    InterestItem('writing', 'Viết lách', 'Writing'),
    InterestItem('design', 'Thiết kế', 'Design'),
  ]),
  InterestGroup('work', 'Nghề nghiệp', 'Profession', <InterestItem>[
    InterestItem('tech', 'Công nghệ', 'Technology'),
    InterestItem('business', 'Kinh doanh', 'Business'),
    InterestItem('education', 'Giáo dục', 'Education'),
    InterestItem('health', 'Y tế', 'Healthcare'),
    InterestItem('engineering', 'Kỹ thuật', 'Engineering'),
    InterestItem('creative_work', 'Sáng tạo nội dung', 'Content creation'),
    InterestItem('student', 'Sinh viên', 'Student'),
    InterestItem('freelance', 'Làm tự do', 'Freelance'),
  ]),
  InterestGroup('hobby', 'Sở thích', 'Hobbies', <InterestItem>[
    InterestItem('travel', 'Du lịch', 'Travel'),
    InterestItem('food', 'Ẩm thực', 'Food'),
    InterestItem('cooking', 'Nấu ăn', 'Cooking'),
    InterestItem('fitness', 'Thể hình', 'Fitness'),
    InterestItem('sports', 'Thể thao', 'Sports'),
    InterestItem('gaming', 'Trò chơi', 'Gaming'),
    InterestItem('reading', 'Đọc sách', 'Reading'),
    InterestItem('pets', 'Thú cưng', 'Pets'),
    InterestItem('fashion', 'Thời trang', 'Fashion'),
    InterestItem('languages', 'Học ngoại ngữ', 'Languages'),
  ]),
];

/// Nhãn của một mã (mã lạ do phiên bản khác thêm → trả chính mã).
String interestLabel(String id, String lang) {
  for (final g in kInterestGroups) {
    for (final i in g.items) {
      if (i.id == id) return i.label(lang);
    }
  }
  return id;
}
