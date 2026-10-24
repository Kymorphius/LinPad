.pushsection .note.Linux, "",@note
    .balign 4
    .long after_name - name // namesz
    .long after_note - note // descz
    .long 0
name:
    .asciz "Linux"
after_name:
    .balign 4
note:
    .long (6 << 16) | (12 << 8) | 0 // 6.12.0
after_note:
    .balign 4
.popsection
