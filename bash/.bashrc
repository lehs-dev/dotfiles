# .bashrc

# --- 1. Phần Mặc Định Của Fedora (Giữ nguyên) ---

# Source global definitions
if [ -f /etc/bashrc ]; then
    . /etc/bashrc
fi

# User specific environment
# Tự động thêm ~/.local/bin vào PATH (Quan trọng cho Starship)
if ! [[ "$PATH" =~ "$HOME/.local/bin:$HOME/bin:" ]]; then
    PATH="$HOME/.local/bin:$HOME/bin:$PATH"
fi
export PATH

# Uncomment the following line if you don't like systemctl's auto-paging feature:
# export SYSTEMD_PAGER=

# --- 2. Cấu hình Cá Nhân (Từ file cũ của bạn) ---

# Lịch sử lệnh (History)
HISTCONTROL=ignoreboth
shopt -s histappend
HISTSIZE=1000
HISTFILESIZE=2000

# Tự cập nhật kích thước cửa sổ (Quan trọng khi resize terminal)
shopt -s checkwinsize

# Màu sắc cho Grep
alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'

# Alias "alert" thông báo khi lệnh chạy xong (Cần gói libnotify)
alias alert='notify-send --urgency=low -i "$([ $? = 0 ] && echo terminal || echo error)" "$(history|tail -n1|sed -e '\''s/^\s*[0-9]\+\s*//;s/[;&|]\s*alert$//'\'')"'

# --- 3. Cấu hình LSD (Thay thế ls) ---
# Kiểm tra xem đã cài lsd chưa để tránh lỗi
if command -v lsd &> /dev/null; then
    alias ls='lsd'
    alias l='lsd -l'
    alias la='lsd -a'
    alias lla='lsd -la'
    alias lt='lsd --tree'
    alias fetch='fastfetch'
else
    # Fallback nếu chưa cài lsd
    alias ls='ls --color=auto'
    alias ll='ls -alF'
    alias la='ls -A'
    alias l='ls -CF'
fi

# --- 4. Load các config rời trong thư mục .bashrc.d (Chuẩn Fedora) ---
# Giữ cái này để hệ thống gọn gàng nếu bạn cài thêm soft khác sau này
if [ -d ~/.bashrc.d ]; then
    for rc in ~/.bashrc.d/*; do
        if [ -f "$rc" ]; then
            . "$rc"
        fi
    done
fi
unset rc

# --- 5. Giao diện & Hiệu ứng (Load sau cùng) ---

export GTK_IM_MODULE=ibus
export QT_IM_MODULE=ibus
export XMODIFIERS=@im=ibus

# Kích hoạt Starship (Prompt)
if command -v starship &> /dev/null; then
    eval "$(starship init bash)"
fi

# Kích hoạt Ble.sh (Auto-suggestion & Syntax highlight)
# LƯU Ý: Ble.sh phải nằm ở CUỐI CÙNG của file
if [ -f ~/.local/share/blesh/ble.sh ]; then
    source ~/.local/share/blesh/ble.sh
fi
