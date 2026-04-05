#!/bin/bash

# --- Bắt đầu quá trình Tái sinh Hệ thống ---
echo "🚀 Đang khởi động tiến trình thiết lập Dotfiles..."

# Lấy đường dẫn thư mục dotfiles hiện tại
DOTFILES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Yêu cầu quyền sudo từ đầu
echo "🔑 Nhập mật khẩu để cài đặt các gói cần thiết:"
sudo -v

# 2. Cài đặt các phần mềm phụ trợ
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

# 6. Phục hồi Mã nguồn Extensions
echo "🧩 Đang nạp mã nguồn Extensions..."
mkdir -p ~/.local/share/gnome-shell/extensions/
cp -r "$DOTFILES_DIR/gnome/extensions/"* ~/.local/share/gnome-shell/extensions/

# 7. Mở khóa Extension an toàn cho GNOME
echo "🔓 Mở khóa tương thích Extension..."
gsettings set org.gnome.shell disable-extension-version-validation true
gsettings set org.gnome.shell disable-user-extensions false

# 8. Bơm dữ liệu cấu hình GNOME (Tuyệt chiêu CHIA ĐỂ TRỊ)
echo "🧠 Đang áp dụng thiết lập hệ thống (Bypass giới hạn dconf)..."
TMP_DCONF="/tmp/gnome_patched.dconf"
sed "s|/home/sonle|/home/$USER|g" "$DOTFILES_DIR/gnome/gnome_full_backup.dconf" > "$TMP_DCONF"

# Tạo thư mục tạm để chứa các phần dconf đã bị cắt nhỏ
mkdir -p /tmp/dconf_split
# Dùng awk cắt file thành từng block riêng biệt dựa vào dòng trống
awk -v RS='' '{print $0 "\n" > ("/tmp/dconf_split/part_" NR ".dconf")}' "$TMP_DCONF"

# Nạp từng block một cách độc lập. Lỗi block nào bỏ qua block đó, không làm hỏng toàn cục!
for file in /tmp/dconf_split/part_*.dconf; do
    dconf load /org/gnome/ < "$file" >/dev/null 2>&1
done

# Dọn dẹp rác
rm -rf /tmp/dconf_split "$TMP_DCONF"

echo "🎉 Xong! Mọi thứ đã hoàn tất."
echo "⚠️ CHÚ Ý QUAN TRỌNG: Hãy Log out (Đăng xuất) và Log in (Đăng nhập) lại ngay bây giờ!"