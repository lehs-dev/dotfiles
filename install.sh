#!/bin/bash

# --- Bắt đầu quá trình Tái sinh Hệ thống ---
echo "🚀 Đang khởi động tiến trình thiết lập Dotfiles..."

# Lấy đường dẫn thư mục dotfiles hiện tại
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Yêu cầu quyền sudo từ đầu
echo "🔑 Nhập mật khẩu để cài đặt các gói cần thiết:"
sudo -v

# 2. Cài đặt các phần mềm phụ trợ (Fedora)
echo "📦 Đang cài đặt lsd, fastfetch, starship..."
sudo dnf install -y lsd fastfetch dconf
curl -sS https://starship.rs/install.sh | sh -s -- -y

# 3. Thiết lập Hình nền
echo "🖼️ Đang thiết lập hình nền..."
mkdir -p ~/.local/share/backgrounds/
cp "$DOTFILES_DIR/wallpapers/"*.jpg ~/.local/share/backgrounds/

# 4. Thiết lập VS Code
echo "💻 Đang thiết lập VS Code..."
VSCODE_DIR="$HOME/.config/Code/User"
mkdir -p "$VSCODE_DIR"
rm -f "$VSCODE_DIR/settings.json"
ln -s "$DOTFILES_DIR/vscode/settings.json" "$VSCODE_DIR/settings.json"

# 5. Thiết lập Bash
echo "⚙️ Đang cấu hình bashrc..."
rm -f ~/.bashrc
ln -s "$DOTFILES_DIR/bash/.bashrc" ~/.bashrc

# 6. Phục hồi MÃ NGUỒN GNOME Extensions (MỚI THÊM)
echo "🧩 Đang nạp mã nguồn Extensions..."
mkdir -p ~/.local/share/gnome-shell/extensions/
# Bê toàn bộ các thư mục extension ông vừa nén dán vào máy mới
cp -r "$DOTFILES_DIR/extensions/"* ~/.local/share/gnome-shell/extensions/

# 7. Bơm dữ liệu cấu hình GNOME & Bật Extension (Tuyệt chiêu cuối)
echo "🧠 Đang áp dụng thiết lập hệ thống và kích hoạt Extension..."
TMP_DCONF="/tmp/gnome_patched.dconf"
sed "s|/home/sonle|/home/$USER|g" "$DOTFILES_DIR/gnome/gnome_full_backup.dconf" > "$TMP_DCONF"
dconf load /org/gnome/ < "$TMP_DCONF"
rm -f "$TMP_DCONF"

echo "🎉 Xong! Mọi thứ đã hoàn tất."
echo "⚠️ CHÚ Ý QUAN TRỌNG: Hãy Log out (Đăng xuất) và Log in (Đăng nhập) lại để GNOME nhận diện thư mục extensions mới copy nhé!"