# koreader-ai-search

Giải nghĩa từ tiếng Anh **theo đúng ngữ cảnh** khi đọc sách trên Kindle bằng KOReader, bằng cả tiếng Anh lẫn tiếng Việt.

*Context-aware English word lookup for KOReader: a plugin that sends the selected word together with its surrounding text to a small AI API (DeepSeek, deployable on Vercel), and shows the answer as the first tab of the dictionary popup.*

Ví dụ: bạn giữ ngón tay lên chữ **bring** trong câu *"He couldn't bring himself to tell her the truth"*. Tab đầu tiên của popup sẽ hiện:

- **bring oneself to do something** · Idiom · Contextual meaning
- **English (B2):** to make yourself do something difficult or unpleasant
- **Tiếng Việt:** đủ can đảm làm điều gì đó khó khăn
- **Trong ngữ cảnh này:** Anh ấy không thể đủ can đảm để nói cho cô ấy biết sự thật.
- **Example:** *She couldn't bring herself to throw away her old letters.* (Cô ấy không nỡ vứt đi những lá thư cũ.)

## Repo có gì

| Đường dẫn | Nội dung |
|---|---|
| `contextdict.koplugin/` | Plugin KOReader ("AI search"). Xem [README của plugin](contextdict.koplugin/README.md). |
| `api/explain.js` | API (Vercel serverless function) gọi DeepSeek. |
| `dev.mjs` | Chạy API trên máy để thử. |
| `tools/mock_server.py` | API giả, để thử plugin khi chưa có key. |

## 1. Deploy API lên Vercel

1. Fork hoặc clone repo này, rồi import vào Vercel. Không cần build gì thêm.
2. Trong *Project Settings → Environment Variables*, thêm hai biến:
   - `DEEPSEEK_API_KEY`: key lấy từ https://platform.deepseek.com/api_keys
   - `APP_TOKEN`: một chuỗi ngẫu nhiên bạn tự đặt, ví dụ tạo bằng `openssl rand -hex 16`. Kindle sẽ gửi nó qua header `Authorization: Bearer <APP_TOKEN>`, và API từ chối mọi request không có nó, nên người khác không dùng được key DeepSeek của bạn.
3. Deploy lại. Địa chỉ API của bạn là `https://<tên-project>.vercel.app/api/explain`.

Biến tùy chọn: `DEEPSEEK_MODEL` (mặc định `deepseek-chat`).

Thử trên máy trước khi deploy: `cp .env.example .env.local`, điền hai biến vào file đó, rồi chạy `node dev.mjs`.

## 2. Cài plugin lên Kindle

1. Chép thư mục `contextdict.koplugin` vào `koreader/plugins/` trên Kindle.
2. Tạo file `contextdict.koplugin/config.lua` trên Kindle. File này đã nằm trong `.gitignore`, không đưa lên GitHub.
   ```lua
   return {
       stamp = "1",  -- đổi giá trị này mỗi khi sửa file, để plugin nạp lại
       api_url = "https://<tên-project>.vercel.app/api/explain",
       api_key = "<APP_TOKEN của bạn>",
   }
   ```
   Thay vì tạo file, bạn cũng có thể nhập trên Kindle: *menu Tìm kiếm (kính lúp) → AI search → Địa chỉ API / API key*.
3. Khởi động lại KOReader, rồi giữ ngón tay lên một từ bất kỳ để thử.

## Chi phí

Mỗi lần tra tốn khoảng vài trăm token DeepSeek, nên 1.000 lần tra chỉ tốn cỡ vài chục cent. Gói miễn phí (Hobby) của Vercel là đủ dùng cho cá nhân.

## License

MIT
