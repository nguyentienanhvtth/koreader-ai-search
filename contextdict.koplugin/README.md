# contextdict.koplugin: "AI search" cho KOReader

Khi bạn tra một từ, plugin gửi từ đó cùng câu và đoạn văn xung quanh lên API. Kết quả (nghĩa tiếng Anh và tiếng Việt **đúng theo ngữ cảnh**) hiện thành **tab đầu tiên** của popup từ điển, tên **AI search**. Các từ điển thường vẫn nằm ở các tab sau.

- Hàng nút **Dictionary | AI search** ở cuối popup dùng để chuyển qua lại. Vuốt trái/phải cũng được.
- Khi bạn kéo chọn nhiều từ (cụm từ, thành ngữ), menu bôi chọn có nút **AI search**.
- Muốn tra AI chỉ khi bấm nút: tắt mục "Tự động tra AI" trong cài đặt.
- Tra lại cùng một từ trong cùng một câu sẽ không gọi API thêm lần nữa.
- Nếu không có mạng hoặc API lỗi, tab AI hiện thông báo; bấm **AI search** để thử lại.

## Cài đặt

Chép thư mục `contextdict.koplugin` vào `koreader/plugins/` trên Kindle, rồi khởi động lại KOReader.

Nếu thư mục có file `config.lua` (dạng `return { stamp = "...", api_url = "...", api_key = "..." }`), plugin tự nạp địa chỉ API và key từ file đó, mỗi giá trị `stamp` mới chỉ nạp một lần.

Cài đặt nằm ở **menu trên cùng → kính lúp (Tìm kiếm) → AI search**: tự động tra, địa chỉ API, API key, số từ ngữ cảnh, thời gian chờ, thử kết nối.

## API contract

### Request

```
POST <địa chỉ API>
Content-Type: application/json; charset=utf-8
Authorization: Bearer <key>      (chỉ có khi bạn đặt API key)
```

```json
{
  "word": "bank",
  "target_lang": "vi",
  "selected_text": "bank",
  "sentence": "After the long walk, they sat down on the grassy bank of the river and watched the boats drift by.",
  "context_before": "…40 từ trước…",
  "context_after": "…40 từ sau…",
  "book": { "title": "The Guest List", "author": "Lucy Foley", "language": "en" }
}
```

- Lúc nào cũng có: `word`, `target_lang`.
- Có thể thiếu: `selected_text`, `sentence`, `context_before`, `context_after`. Chúng vắng mặt khi không lấy được ngữ cảnh, ví dụ khi tra một từ nằm trong phần định nghĩa của từ điển. Khi đó API nên giải nghĩa chung.
- `book` và các trường bên trong cũng có thể thiếu.
- `sentence` do plugin tự cắt theo dấu `. ! ?`, nên có thể chưa chuẩn (ví dụ gặp “Mr.”). Nếu cần, hãy dựa vào `context_before` và `context_after`.

### Response (HTTP 200, JSON)

Mọi trường đều tùy chọn. Trường nào có thì plugin hiển thị trường đó.

```json
{
  "word": "bank",
  "lemma": "bank",
  "ipa": "/bæŋk/",
  "part_of_speech": "noun",
  "cefr_level": "A2",
  "meaning_vi": "bờ (sông)",
  "meaning_en": "the land along the side of a river",
  "explanation_vi": "Có 'river' và 'grassy' nên đây là bờ sông, không phải ngân hàng.",
  "explanation_en": "…",
  "sentence_vi": "Sau chặng đi bộ dài, họ ngồi xuống bờ sông đầy cỏ và ngắm thuyền trôi.",
  "other_meanings": ["ngân hàng", "dãy (nút, đèn…)"],
  "examples": [{ "en": "We had a picnic on the river bank.", "vi": "Chúng tôi picnic trên bờ sông." }]
}
```

Nếu muốn tự quyết định giao diện, API có thể trả `{"html": "<p>…</p>"}`. Khi có trường này, plugin hiển thị nguyên đoạn HTML đó và bỏ qua các trường khác.

Khi có lỗi, trả HTTP 4xx/5xx kèm `{"error": "nội dung lỗi"}`. Plugin sẽ hiện nội dung này cho người dùng.

## Thử với mock server

```bash
python3 tools/mock_server.py
```

Server in ra địa chỉ cần nhập trên Kindle. Kindle và Mac phải dùng chung mạng Wi-Fi.
Mỗi request từ Kindle được in ra terminal, nên bạn xem được chính xác Kindle gửi lên những gì.
