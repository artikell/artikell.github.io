---
title: VIM配置分享
date: 2022-04-28 19:50:07
tags:
---

```
call plug#begin('~/.vim/plugged')
Plug 'itchyny/lightline.vim'
Plug 'junegunn/fzf'
Plug 'junegunn/fzf.vim'
Plug 'terryma/vim-multiple-cursors'
Plug 'scrooloose/nerdtree'
Plug 'vim-airline/vim-airline'
Plug 'vim-airline/vim-airline-themes'
Plug 'bling/vim-bufferline'
Plug 'fatih/vim-go', { 'do': ':GoUpdateBinaries' }
Plug 'Blackrush/vim-gocode'
Plug 'Valloric/YouCompleteMe'
Plug 'honza/vim-snippets'
Plug 'majutsushi/tagbar'
Plug 'marijnh/tern_for_vim'
Plug 'Xuyuanp/nerdtree-git-plugin'
Plug 'SirVer/ultisnips'
Plug 'vim-scripts/mru.vim'
Plug 'mhinz/vim-startify'
Plug 'mhinz/vim-startify'
call plug#end()


" Vim 基础设置
let mapleader=" "
set number
set tabstop=4
set expandtab
set smartindent
set fdm=indent
set list
set listchars=tab:\ \ ,trail:.
set hlsearch
highlight WhitespaceEOL ctermbg=red guibg=red
match WhitespaceEOL /\s\+$/
let g:airline#extensions#tabline#enabled=1 "顶部tab显示"

" 自定义改键
map <leader>w :w<CR>
map <leader>q :q<CR>
map <leader>wq :wq<CR>
map <leader>ws :source ~/.vimrc<CR>
map <leader>f /
map <leader>fh :noh<CR>
map <leader>fp :Files<CR>
nmap <tab> :bn<cr> "设置tab键映射"
nnoremap <leader>y :call system('nc localhost 8377', @0)<CR>

" NerdTree 设置
" 关闭NERDTree快捷键
map <leader>t :NERDTreeToggle<CR>
" 显示行号
let NERDTreeShowLineNumbers=1
let NERDTreeAutoCenter=1
" 是否显示隐藏文件
" let NERDTreeShowHidden=1
" let NERDTreeShowBookmarks=0
" 设置宽度
let NERDTreeWinSize=31
" 在终端启动vim时，共享NERDTree
let g:nerdtree_tabs_open_on_console_startup=1
" 忽略一下文件的显示
let NERDTreeIgnore=['\.pyc','\~$','\.swp']
" 显示书签列表
let NERDTreeShowBookmarks=1
set rtp+=~/.fzf



command! -bang -nargs=* Ag call fzf#vim#ag(<q-args>, {'options': '--delimiter : --nth 4..'}, <bang>0)
nnoremap <silent> <Leader>a :Ag <C-R><C-W><CR>
```