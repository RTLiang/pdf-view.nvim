" VimTeX viewer adapter: :VimtexView / <localleader>lv use the in-process PDF viewer.
function! vimtex#view#pdf_view#new() abort
  return s:viewer.init()
endfunction

let s:viewer = vimtex#view#_template#new({'name': 'pdf-view.nvim'})

function! s:viewer._check() abort
  return has('nvim') && executable('mutool') && executable('synctex')
endfunction

function! s:viewer._start(outfile) dict abort
  call luaeval("require('pdf-view').forward(_A)", {
        \ 'pdf': a:outfile,
        \ 'source': expand('%:p'),
        \ 'line': line('.'),
        \ 'column': col('.'),
        \ 'root': b:vimtex.root,
        \ })
endfunction
