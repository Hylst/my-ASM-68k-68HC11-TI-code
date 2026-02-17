; *************************************************************
; * 3D STARFIELD - FULL OPTIMIZED VERSION               *
; * Projets : Demomaking Atari ST                             *
; * Caractéristiques : Multi-Planar, Precomputed Z, No DIV    *
; *************************************************************

        output  .tos

; --- Constantes ---
NB_STARS equ 200            ; Nombre d'étoiles
MAX_Z    equ 512            ; Profondeur max
Z_SPEED  equ 6              ; Vitesse d'avance

        SECTION TEXT

start:
        ; --- Passage en mode Superviseur ---
        clr.l   -(sp)
        move.w  #32,-(sp)
        trap    #1
        addq.l  #6,sp
        move.l  d0,old_stack

        ; --- Sauvegarde et Init Vidéo ---
        move.w  #2,-(sp)            ; Physbase
        trap    #14
        addq.l  #2,sp
        move.l  d0,old_screen

        ; Préparation des buffers écrans alignés
        move.l  #screen_mem,d0
        add.l   #255,d0
        clr.b   d0                  ; Aligne sur 256 octets
        move.l  d0,screen_1
        add.l   #32000,d0
        move.l  d0,screen_2

        ; --- Initialisations ---
        bsr     init_palette
        bsr     gen_z_table         ; Table 1/Z
        bsr     init_stars          ; Positions de départ
        
        ; Cache la souris (VDI/AES)
        dc.w    $a00a

main_loop:
        bsr     wait_vbl

        ; --- Double Buffering (Swap) ---
        move.l  screen_1,d0
        move.l  screen_2,d1
        move.l  d1,screen_1         ; Ecran visible
        move.l  d0,screen_2         ; Ecran de travail (LOGBASE)

        move.w  #-1,-(sp)           ; Mode inchangé
        move.l  screen_1,-(sp)      ; Phys
        move.l  screen_2,-(sp)      ; Log
        move.w  #5,-(sp)            ; Setscreen
        trap    #14
        lea     12(sp),sp

        ; --- Moteur de Rendu ---
        bsr     erase_stars         ; Efface uniquement les pixels d'avant
        bsr     move_stars          ; Calcule et dessine

        ; Test de sortie (Touche Espace)
        cmpi.b  #$39,$fffc02.w
        bne.s   main_loop

exit:
        ; --- Restauration du système ---
        move.w  #-1,-(sp)
        move.l  old_screen,-(sp)
        move.l  old_screen,-(sp)
        move.w  #5,-(sp)
        trap    #14
        lea     12(sp),sp

        dc.w    $a009               ; Montre la souris
        move.l  old_stack,-(sp)
        move.w  #32,-(sp)
        trap    #1
        addq.l  #6,sp
        
        clr.w   -(sp)               ; Pterm()
        trap    #1

; *************************************************************
; * ROUTINES DE CALCUL ET DESSIN                              *
; *************************************************************

gen_z_table:
        ; Pré-calcule 16384 / Z pour éviter les divisions en boucle
        lea     z_table,a0
        move.w  #1,d7
.loop:
        move.l  #16384,d0
        divu    d7,d0
        move.w  d0,(a0)+
        addq.w  #1,d7
        cmp.w   #MAX_Z,d7
        blt.s   .loop
        rts

init_stars:
        lea     star_data,a0
        move.w  #NB_STARS-1,d7
        move.w  #$1234,d0           ; Graine aléatoire
.loop:
        ; Random X
        rol.w   #7,d0
        add.w   #$4321,d0
        move.w  d0,d1
        and.w   #1023,d1
        sub.w   #512,d1
        move.w  d1,(a0)+            ; X
        ; Random Y
        rol.w   #3,d0
        move.w  d0,d1
        and.w   #1023,d1
        sub.w   #512,d1
        move.w  d1,(a0)+            ; Y
        ; Random Z
        rol.w   #5,d0
        move.w  d0,d1
        and.w   #MAX_Z-1,d1
        addq.w  #1,d1
        move.w  d1,(a0)+            ; Z
        
        move.l  #-1,(a0)+           ; Old offset (-1 = pas encore dessiné)
        dbf     d7,.loop
        rts

erase_stars:
        ; Effacement optimisé : on ne touche qu'aux pixels utilisés
        move.l  screen_2,a0
        lea     star_data,a1
        move.w  #NB_STARS-1,d7
.loop:
        move.l  6(a1),d0            ; Récupère l'offset stocké
        bmi.s   .no_erase
        move.l  d0,a2
        moveq   #0,d1
        move.w  d1,(a0,a2.l)        ; Efface Plan 0
        move.w  d1,2(a0,a2.l)       ; Efface Plan 1
        move.w  d1,4(a0,a2.l)       ; Efface Plan 2
        move.w  d1,6(a0,a2.l)       ; Efface Plan 3
.no_erase:
        lea     10(a1),a1
        dbf     d7,.loop
        rts

move_stars:
        lea     star_data,a1
        lea     z_table,a2
        lea     bit_lookup,a3
        move.l  screen_2,a4
        move.w  #NB_STARS-1,d7

.loop:
        ; Mise à jour Z
        move.w  4(a1),d2            ; Z
        subq.w  #Z_SPEED,d2
        bgt.s   .z_ok
        move.w  #MAX_Z-1,d2         ; Reset au fond
.z_ok:
        move.w  d2,4(a1)

        ; Projection 3D (Z-Lookup)
        move.w  d2,d3
        add.w   d3,d3               ; Index de mot
        move.w  (a2,d3.w),d3        ; d3 = Factor (16384/Z)

        ; X
        move.w  (a1),d0             ; X
        muls    d3,d0               ; X * (16384/Z)
        asr.l   #6,d0               ; Ajustement virgule fixe
        add.w   #160,d0             ; Centrage
        ; Y
        move.w  2(a1),d1            ; Y
        muls    d3,d1
        asr.l   #6,d1
        add.w   #100,d1             ; Centrage

        ; Clipping 320x200
        cmp.w   #319,d0
        bhi.s   .out
        cmp.w   #199,d1
        bhi.s   .out

        ; --- Calcul d'adresse écran ---
        move.w  d1,d4
        mulu    #160,d4             ; Y * 160
        move.w  d0,d5
        lsr.w   #4,d5               ; X / 16
        lsl.w   #3,d5               ; * 8 octets par bloc
        add.w   d5,d4               ; d4 = Offset Final
        move.l  d4,6(a1)            ; Sauve pour l'effaçage

        ; --- Plot du pixel (Multi-Planar) ---
        move.w  d0,d5
        and.w   #15,d5              ; X mod 16
        add.w   d5,d5
        move.w  (a3,d5.w),d6        ; Bit masque
        
        move.l  a4,a0
        add.l   d4,a0               ; Adresse RAM vidéo

        ; Logique de plans selon la profondeur Z
        cmp.w   #150,d2             ; Si très proche
        blt.s   .bright
        cmp.w   #300,d2             ; Si distance moyenne
        blt.s   .medium

.dark:  or.w    d6,(a0)             ; Gris sombre (Plan 0)
        bra.s   .next
.medium:
        or.w    d6,(a0)             ; Gris clair (Plans 0+1)
        or.w    d6,2(a0)
        bra.s   .next
.bright:
        or.w    d6,(a0)             ; Blanc (Tous les plans)
        or.w    d6,2(a0)
        or.w    d6,4(a0)
        or.w    d6,6(a0)
        bra.s   .next

.out:   move.l  #-1,6(a1)           ; Indique hors-écran
.next:  lea     10(a1),a1           ; Etoile suivante
        dbf     d7,.loop
        rts

wait_vbl:
        move.w  #37,-(sp)
        trap    #14
        addq.l  #2,sp
        rts

init_palette:
        move.w  #$000,$ff8240.w     ; Couleur 0 : Noir
        move.w  #$333,$ff8242.w     ; Couleur 1 : Gris sombre
        move.w  #$555,$ff8246.w     ; Couleur 3 : Gris clair
        move.w  #$777,$ff824e.w     ; Couleur 7 : Blanc (Indices via plans)
        rts

; *************************************************************
; * DONNEES                                                   *
; *************************************************************

        SECTION DATA
        even
bit_lookup:
        dc.w $8000,$4000,$2000,$1000,$0800,$0400,$0200,$0100
        dc.w $0080,$0040,$0020,$0010,$0008,$0004,$0002,$0001

        SECTION BSS
        even
old_stack:  ds.l 1
old_screen: ds.l 1
screen_1:   ds.l 1
screen_2:   ds.l 1

z_table:    ds.w MAX_Z
; Structure étoile : X(w), Y(w), Z(w), OldOffset(l) = 10 octets
star_data:  ds.b 10*NB_STARS

            ds.b 256                ; Padding alignement
screen_mem: ds.b 64000+256          ; Buffers vidéo

        END