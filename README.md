# Fedora Workstation dotfiles

Đây là snapshot có kiểm soát của máy Fedora Workstation hiện tại, dùng để dựng
lại môi trường desktop trên một máy mới. Bundle được pin cho **Fedora 44 / GNOME
Shell 50**; installer sẽ dừng trước khi thay đổi hệ thống nếu GNOME khác major 50.

## Cài trên máy mới

Sau khi cài Fedora Workstation và kết nối Internet:

```bash
git clone <PRIVATE_REPOSITORY_URL> ~/dotfiles
cd ~/dotfiles
./install.sh --dry-run
./install.sh
./scripts/audit.sh
```

Không chạy toàn bộ script bằng `sudo`. Script tự gọi `sudo` đúng lúc để cài RPM,
Flatpak và đổi login shell. Sau khi hoàn tất, đăng xuất rồi đăng nhập lại.
Installer tự chạy audit sau khi cài các công cụ kiểm tra; lệnh audit cuối chỉ là
một lần xác nhận bổ sung.

Mỗi lần chạy thật, các file đích, repo RPM, login shell và toàn bộ nhánh dconf
được quản lý sẽ được sao lưu tại:

```text
~/.local/state/fedora-dotfiles/backups/<timestamp>/
```

## Những gì được khôi phục

- 18 RPM thiết yếu, ba repo đang thực sự được dùng: Brave, VSCodium và COPR
  Starship.
- Extension Manager từ Flathub.
- Fish, Starship, lsd, bat; cấu hình Fcitx5/Unikey và biến môi trường input method.
- VSCodium settings cùng `openai.chatgpt` và Prettier. Prettier được thêm vì
  settings hiện tại tham chiếu trực tiếp tới formatter này.
- JetBrainsMono Nerd Font 3.5.0 được tải từ release đã pin và kiểm SHA-256; font
  không được nhét vào Git nên repo chỉ khoảng 13 MB.
- Bốn wallpaper, custom sound theme và các lựa chọn GNOME/dconf đã được lọc.
- Bảy GNOME extension đang dùng, gồm nguyên source và schema:
  Dash2Dock Lite, Static Workspace Background, Blur My Shell, Magic Lamp,
  Search Light, Kimpanel và Light Style.
- Bản vá Magic Lamp/Dash2Dock: cửa sổ ở màn hình không có dock sẽ thu về dock
  của màn hình chính; nếu không tìm thấy icon app thì thu về cạnh giữa của dock.
- Blur My Shell được ghi rõ thành panel-only: panel bật; overview, app folder,
  applications, dock, screenshot, lock screen, window list và coverflow tắt.
- Cấu hình Codex an toàn gồm model/reasoning/service tier. Đăng nhập, session,
  project trust và cache plugin không được mang theo.

## Những gì cố ý không đưa vào Git

- Token Codex, cookie trình duyệt, keyring, chứng chỉ, GNOME Online Accounts,
  email/Evolution, history, cache, workspaceStorage và machine UUID.
- `monitors.xml`, ICC profile, trạng thái systemd/phần cứng và dữ liệu EDID.
- Toàn bộ 1.843 RPM không được cài lại máy móc. Danh sách đầy đủ chỉ nằm trong
  `inventory/`; installer dùng manifest 18 gói có chủ đích để tránh kéo trạng
  thái Live image, kernel và firmware của máy cũ sang máy mới.
- Codex plugin cache. `manifests/codex-plugins.txt` chỉ là inventory; cần kết nối
  lại plugin sau khi đăng nhập.

Trình duyệt, Codex và GNOME Online Accounts phải đăng nhập lại. Nên dùng remote
Git **private**, nhất là vì bundle chứa wallpaper và các sở thích cá nhân.

## Tùy chọn installer

```text
--dry-run              Chỉ hiển thị, không thay đổi máy
--skip-packages        Bỏ qua RPM/repo
--skip-flatpak         Bỏ qua Flathub/Flatpak
--skip-font            Bỏ qua Nerd Font
--prune-default-apps   Gỡ các app Fedora đã bị gỡ trên máy nguồn, có xác nhận
--with-monitor-layout  Khôi phục monitors.xml phần cứng, nếu đã lưu riêng
--yes                  Không hỏi lại khi prune app mặc định
```

Không dùng `--prune-default-apps` mặc định: riêng GNOME Boxes có thể kéo theo
việc gỡ một lượng lớn dependency ảo hóa.

## Cập nhật snapshot

Trên máy nguồn:

```bash
cd ~/Desktop/dotfiles
./scripts/snapshot.sh
git diff
./scripts/audit.sh
git add .
git commit -m "Refresh Fedora desktop snapshot"
git push
```

`snapshot.sh` chỉ đọc các đường dẫn trong allowlist. Muốn lưu monitor layout cho
đúng thiết bị cũ, chạy `./scripts/snapshot.sh --include-monitor-layout`; file này
vẫn bị `.gitignore` chặn và chỉ nên `git add -f` vào một remote private.

Không tự cập nhật bundle này sau khi nâng Fedora/GNOME. Hãy cập nhật từng
extension, chạy lại snapshot và audit trước. Extension Manager cũng có thể ghi
đè bản vá Dash2Dock cục bộ; chạy lại installer sẽ phục hồi bản đã pin trong repo.

## Các lựa chọn chưa tự ý thay đổi

- F12 vẫn mở Calculator và có thể chặn Go to Definition trong VSCodium.
- Ctrl+Space vẫn là phím chuyển Fcitx và có thể chặn Trigger Suggest.
- Python bật format-on-save nhưng chưa chọn Ruff hay Black; cần chọn formatter
  theo workflow dự án.
- Fish aliases/Starship hiện vẫn chạy cả trong shell không tương tác, đúng với
  cấu hình nguồn.
- Cấu hình hiện tại không tự khóa/suspend (`idle-delay=0`, sleep AC/battery là
  `nothing`) và được giữ nguyên theo yêu cầu snapshot.

Các mục trên được giữ nguyên vì đổi chúng cần lựa chọn cá nhân, không phải lỗi
bootstrap.
