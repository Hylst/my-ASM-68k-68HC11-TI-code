; *************************************************************
; * 5 DISTORTED SPRITES DEMO - STEP 1                         *
; * Architecture, Lissajous & Distortion Tables               *
; *************************************************************

        output  .tos

        SECTION TEXT

start:
        ; --- Mode Superviseur ---
        clr.l   -(sp)
        move.w  #32,-(sp)
        trap    #1
        addq.l  #6,sp
        move.l  d0,old_stack

        ; --- Sauvegarde & Init Vidéo ---
        move.w  #2,-(sp)            ; Physbase
        trap    #14
        addq.l  #2,sp
        move.l  d0,old_screen

        ; Buffers écrans (alignés sur 256 octets)
        move.l  #screen_mem,d0
        add.l   #255,d0
        clr.b   d0
        move.l  d0,screen_1
        add.l   #32000,d0
        move.l  d0,screen_2

        ; --- Initialisation des Tables ---
        bsr     gen_tables          ; Trajectoires et Distorsion
        bsr     init_palette

main_loop:
        bsr     wait_vbl

        ; --- Double Buffering ---
        move.l  screen_1,d0
        move.l  screen_2,d1
        move.l  d1,screen_1         ; On affiche l'un
        move.l  d0,screen_2         ; On dessine sur l'autre

        move.w  #-1,-(sp)
        move.l  screen_1,-(sp)      ; Phys
        move.l  screen_2,-(sp)      ; Log
        move.w  #5,-(sp)            ; Setscreen
        trap    #14
        lea     12(sp),sp

        ; --- Nettoyage ---
        move.l  screen_2,a0
        bsr     clear_sprites_bg    ; On efface les positions précédentes

        ; --- Mise à jour des positions & Dessin ---
        ; (Sera détaillé en étape 2)
        bsr     move_and_draw_sprites

        ; Test Sortie
        cmpi.b  #$39,$fffc02.w
        bne.s   main_loop
		
		
; *************************************************************
; * THE DISTORTED BLITTER                            *
; *************************************************************

move_and_draw_sprites:
    move.w  sine_index,d6           
    move.w  distort_index,d5        ; L'index de distorsion évolue !
    move.w  #5-1,d7                 ; 5 sprites

.loop_sprites:
    lea     sin_table,a0
    move.w  d6,d0
    and.w   #1022,d0
    move.w  (a0,d0.w),d1            ; X
    add.w   #140,d1                 

    move.w  d6,d0
    lsl.w   #1,d0
    and.w   #1022,d0
    move.w  (a0,d0.w),d2            ; Y
    asr.w   #1,d2
    add.w   #80,d2

    movem.l d5-d7,-(sp)             ; Sauvegarde index
    bsr     draw_masked_distorted   ; On appelle le gros morceau
    movem.l (sp)+,d5-d7

    add.w   #120,d6                 ; Espacement des sprites sur la courbe
    add.w   #40,d5                  ; Décale la phase de distorsion par sprite
    dbf     d7,.loop_sprites

    addq.w  #4,distort_index        ; Fait bouger la "vague"
    and.w   #1022,distort_index
    rts

; --- Blitter avec Masque et Distorsion ---
draw_masked_distorted:
    lea     sprite_gfx(pc),a2
    lea     sprite_mask(pc),a3
    move.l  screen_2,a0
    
    mulu.w  #160,d2
    add.l   d2,a0
    move.w  d1,d0
    lsr.w   #4,d0
    lsl.w   #3,d0
    add.w   d0,a0                   ; A0 = destination écran

    lea     distort_table,a1
    move.w  #32-1,d7                ; 32 lignes
.line:
    move.w  d5,d0
    and.w   #254,d0
    move.w  (a1,d0.w),d3            ; D3 = décalage (0-15)

    ; On charge Data et Masque
    move.l  (a2)+,d0                ; GFX Plane 0
    move.l  (a3)+,d4                ; MASK
    
    ; Application de la distorsion (shift)
    lsr.l   d3,d0
    lsr.l   d3,d4
    not.l   d4                      ; Invert masque pour AND

    ; --- Opération de Blitting ---
    ; 1. On efface le fond avec le masque
    and.l   d4,(a0)
    and.l   d4,4(a0)
    ; 2. On pose le sprite
    or.l    d0,(a0)                 
    or.l    d0,4(a0)                ; Copie sur Plane 1 pour la couleur

    add.w   #160,a0
    addq.w  #2,d5
    dbf     d7,.line
    rts

; --- Routine de dessin d'un sprite 32x32 ---
; D1 = X, D2 = Y, A2 = Sprite Data
draw_distorted_sprite:
    move.l  screen_2,a0             ; Buffer de dessin
    
    ; Calcul de l'adresse de base (Y * 160)
    mulu.w  #160,d2
    add.l   d2,a0
    
    ; Calcul de l'offset X (X / 16) * 8
    move.w  d1,d0
    lsr.w   #4,d0
    lsl.w   #3,d0
    add.w   d0,a0                   ; A0 pointe maintenant sur l'écran

    ; Préparation de la distorsion
    move.w  distort_index,d5
    lea     distort_table,a1
    
    move.w  #32-1,d7                ; 32 lignes de haut
.draw_line:
    ; On récupère l'offset de distorsion pour cette ligne
    move.w  d5,d0
    and.w   #254,d0                 ; Table de 128 mots
    move.w  (a1,d0.w),d3            ; D3 = décalage horizontal (0-15)
    
    ; Note : Pour cette étape, on simplifie le décalage à l'octet
    ; Un vrai pré-shift 16 positions prendrait trop de place ici.
    ; On dessine 2 plans sur 4 (couleurs simplifiées)
    
    move.l  (a2)+,d0                ; Data Plane 0
    move.l  (a2)+,d4                ; Data Plane 1
    
    ; Application sommaire de la distorsion (décalage de bit)
    lsr.l   d3,d0
    lsr.l   d3,d4
    
    ; On trace sur l'écran (sur 2 mots de large pour 32 pixels)
    or.l    d0,(a0)                 ; Ecrit Plane 0 (pixels 0-31)
    or.l    d4,4(a0)                ; Ecrit Plane 1 (pixels 0-31)
    
    add.w   #160,a0                 ; Ligne suivante écran
    addq.w  #2,d5                   ; Suivant dans table distorsion
    dbf     d7,.draw_line
    
    rts
	
exit:
        ; Restauration
        move.w  #-1,-(sp)
        move.l  old_screen,-(sp)
        move.l  old_screen,-(sp)
        move.w  #5,-(sp)
        trap    #14
        lea     12(sp),sp

        move.l  old_stack,-(sp)
        move.w  #32,-(sp)
        trap    #1
        addq.l  #6,sp
        clr.w   -(sp)
        trap    #1

; *************************************************************
; * GENERATION DES TABLES                                     *
; *************************************************************

gen_tables:
        ; Table de trajectoire (Sinus 512 entrées)
        lea     sin_table,a0
        move.w  #0,d0               ; Y
        move.w  #10000,d1           ; X
        move.w  #511,d7
.loop_sin:
        move.w  d0,d2
        asr.w   #7,d2               ; Scale
        move.w  d2,(a0)+
        
        move.w  d0,d2
        asr.w   #7,d2
        sub.w   d2,d1
        move.w  d1,d2
        asr.w   #7,d2
        add.w   d2,d0
        dbf     d7,.loop_sin

        ; Table de distorsion (Offset horizontal par ligne)
        lea     distort_table,a0
        move.w  #0,d0
        move.w  #500,d1             ; Petite amplitude
        move.w  #127,d7
.loop_dist:
        move.w  d0,d2
        asr.w   #8,d2
        move.w  d2,(a0)+
        ; Minsky...
        move.w  d0,d3
        asr.w   #5,d3
        sub.w   d3,d1
        move.w  d1,d3
        asr.w   #5,d3
        add.w   d3,d0
        dbf     d7,.loop_dist
        rts

init_palette:
        move.w  #$000,$ff8240.w     ; Noir
        move.w  #$700,$ff8242.w     ; Rouge
        move.w  #$770,$ff8244.w     ; Jaune
        move.w  #$777,$ff8246.w     ; Blanc
        rts

wait_vbl:
        move.w  #37,-(sp)
        trap    #14
        addq.l  #2,sp
        rts

clear_sprites_bg:
        ; Ici on pourrait faire un CLS complet ou un effaçage ciblé
        ; Pour la démo, un CLS rapide suffit :
        move.w  #2000-1,d7
        moveq   #0,d0
.cl:    move.l  d0,(a0)+
        move.l  d0,(a0)+
        move.l  d0,(a0)+
        move.l  d0,(a0)+
        dbf     d7,.cl
        rts

; *************************************************************
; * DATA SPRITE (32x32 simplifié / temporaire)                *
; *************************************************************

    SECTION DATA
	
sine_index:     dc.w 0
distort_index:  dc.w 0
	
sprite_data:
    ; Un carré creux pour le test
    dcb.l   4,$FFFFFFFF             ; Ligne 1 (Planes 0 et 1)
    rept    30
    dc.l    $80000001,$80000001     ; Milieu
    endr
    dcb.l   4,$FFFFFFFF             ; Ligne 32		
		
even
sprite_gfx:
    ; Un motif de losange 32x32
    dcb.l   8,$00181800             ; Haut
    dcb.l   8,$007E7E00             ; Milieu haut
    dcb.l   8,$00FFFFFF             ; Centre
    dcb.l   8,$007E7E00             ; Milieu bas
    
sprite_mask:
    ; Le masque doit être un peu plus large que le sprite
    dcb.l   8,$003C3C00
    dcb.l   8,$00FFFF00
    dcb.l   8,$00FFFFFF
    dcb.l   8,$00FFFF00

    SECTION BSS
	
	    even
distort_index: 	ds.w 1

old_stack:      ds.l 1
old_screen:     ds.l 1
screen_1:       ds.l 1
screen_2:       ds.l 1
sin_table:      ds.w 512
distort_table:  ds.w 128
                ds.b 256
screen_mem:     ds.b 64000+256


; Prevoir pre shifting sprites