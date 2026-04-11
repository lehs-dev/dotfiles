# Tự động thêm thư mục cá nhân vào biến PATH
fish_add_path ~/.local/bin ~/bin

# Sửa lỗi gõ tiếng Việt trên các app GTK/QT
set -gx GTK_IM_MODULE ibus
set -gx QT_IM_MODULE ibus
set -gx XMODIFIERS @im=ibus

# Màu sắc cho lệnh tìm kiếm
alias grep 'grep --color=auto'
alias fgrep 'fgrep --color=auto'
alias egrep 'egrep --color=auto'

# Nâng cấp lệnh ls thành lsd siêu đẹp
if type -q lsd
    alias ls lsd
    alias l 'lsd -l'
    alias la 'lsd -a'
    alias lla 'lsd -la'
    alias lt 'lsd --tree'
    alias fetch fastfetch
else
    alias ls 'ls --color=auto'
    alias ll 'ls -alF'
end

# Tắt lời chào của Fish cho gọn terminal
set -g fish_greeting ""

# Kích hoạt giao diện prompt Starship
if type -q starship
    starship init fish | source
end