; *************************************************************
; * SINUS SCROLLTEXT + RASTERS - ATARI ST                     *
; * Technique : Interruption Timer B & Pré-décalage           *
; *************************************************************

; à compléter

        output  .tos

        SECTION TEXT

start:
        ; --- Mode Superviseur ---
        clr.l   -(sp)
        move.w  #32,-(sp)
        trap    #1
        addq.l  #6,sp
        move.l  d0,old_stack

        ; --- Initialisation Vidéo ---
        move.w  #2,-(sp)
        trap    #14
        addq.l  #2,sp
        move.l  d0,old_screen

        ; Buffers alignés
        move.l  #screen_mem,d0
        add.l   #255,d0
        clr.b   d0
        move.l  d0,screen_1

        ; --- Pré-calculs ---
        bsr     gen_sine_table      ; Table d'ondulation
        bsr     clear_screen

        ; --- Installation interruptions ---
        move.w  sr,old_sr
        move.l  $70.w,old_vbl
        move.l  $120.w,old_timerb
        
        move.w  #$2700,sr           ; Coupe interruptions
        move.l  #my_vbl,$70.w
        move.l  #my_timerb,$120.w
        bset    #0,$fffa07.w        ; Enable Timer B
        bset    #0,$fffa13.w        ; Mask Timer B
        move.w  #$2300,sr           ; OK

main_loop:
        stop    #$2300              ; Sync VBL
        
        bsr     update_scroll       ; Gère le défilement du texte
        
        ; Animation des index
        addq.w  #2,sine_ptr
        and.w   #511,sine_ptr
        
        cmpi.b  #$39,$fffc02.w      ; Espace pour quitter
        bne.s   main_loop

exit:
        ; --- Restauration ---
        move.w  #$2700,sr
        move.l  old_vbl,$70.w
        move.l  old_timerb,$120.w
        move.b  #$00,$fffa1b.w      ; Stop Timer B
        move.w  old_sr,sr
        
        move.l  old_stack,-(sp)
        move.w  #32,-(sp)
        trap    #1
        addq.l  #6,sp
        clr.w   -(sp)
        trap    #1

; *************************************************************
; * ROUTINES D'INTERRUPTIONS                                  *
; *************************************************************

my_vbl:
        clr.b   $fffa1b.w           ; Stop Timer B
        move.b  #100,$fffa21.w      ; Attend la ligne 100 (début scroll)
        move.b  #8,$fffa1b.w        ; Mode HBL
        
        move.l  #raster_tab,raster_ptr
        move.w  sine_ptr,d0
        move.w  d0,current_sine_off ; Position départ sinus
        
        move.w  #$000,$ff8240.w     ; Fond noir
        rte

my_timerb:
        ; --- Effet de Sinus (Distorsion ligne par ligne) ---
        move.l  a0,-(sp)
        move.w  current_sine_off,d0
        lea     sine_table,a0
        move.w  (a0,d0.w*2),d1      ; Récupère décalage X
        
        ; Ici, on change le registre de scroll horizontal (HSCROLL)
        ; uniquement disponible sur STE. Pour STF, on joue sur
        ; le décalage des mots mémoires dans le buffer.
        ; Pour cette démo, on utilise le Timer B pour les Rasters :
        move.l  raster_ptr,a0
        move.w  (a0)+,$ff8240.w     ; Change couleur fond
        move.l  a0,raster_ptr
        
        addq.w  #2,current_sine_off
        and.w   #511,current_sine_off
        
        move.l  (sp)+,a0
        bclr    #0,$fffa0f.w
        rte
		
; *************************************************************
; * SECTION DATA ET ROUTINES COMPLÉMENTAIRES                  *
; *************************************************************

        SECTION DATA

; Table de couleurs pour les Rasters (Dégradé)
raster_tab:
        dc.w $001,$102,$203,$304,$405,$506,$607,$707,$606,$505,$404,$303,$202,$101,$000
raster_ptr: dc.l 0

; Texte qui défile
scroll_text:
        dc.b "    BIENVENUE SUR ATARI ST ... CE SCROLLTEXT ONDULE "
        dc.b "GRACE AU TIMER B ET UNE TABLE DE SINUS PRECALCULEE ... "
        dc.b "L'ASSEMBLEUR 68000 EST MAGIQUE !     ",0
        even

; Table de Sinus (Mouvement horizontal)
gen_sine_table:
        lea     sine_table,a0
        move.w  #511,d7
        move.w  #0,d0
.l:     move.w  d0,d1
        asr.w   #8,d1               ; Amplitude réduite
        move.w  d1,(a0)+
        ; Minsky loop simple
        add.w   #5,d0
        dbf     d7,.l
        rts

update_scroll:
        ; Cette routine dessine le texte et le décale
        ; Sur STF, on utilise un buffer de pré-décalage (16 pixels)
        ; Pour rester concis, on simule ici un décalage de bloc mémoire
        lea     scroll_text,a0
        add.w   text_ptr,a0
        move.b  (a0),d0
        bne.s   .not_end
        move.w  #0,text_ptr         ; Loop texte
        rts
.not_end:
        ; Dessin simple d'un caractère (8x8 ou 16x16)
        ; [Routine de blit caractère ici]
        addq.w  #1,text_ptr
        rts

clear_screen:
        move.l  screen_1,a0
        move.w  #7999,d7
.c:     clr.l   (a0)+
        dbf     d7,.c
        rts

        SECTION BSS
        even
old_stack:   ds.l 1
old_screen:  ds.l 1
old_vbl:     ds.l 1
old_timerb:  ds.l 1
old_sr:      ds.w 1
screen_1:    ds.l 1
sine_ptr:    ds.w 1
current_sine_off: ds.w 1
text_ptr:    ds.w 1
sine_table:  ds.w 512
             ds.b 256
screen_mem:  ds.b 32000+256
        END