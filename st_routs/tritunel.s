; *************************************************************
; * TRIANGULAR TUNNEL - ATARI ST DEMOSCENE STYLE              *
; * Features: Double Buffering, 3D Projection, Bresenham      *
; *************************************************************

        output  .tos

        SECTION TEXT

start:
        ; --- Passage en mode Superviseur ---
        clr.l   -(sp)
        move.w  #32,-(sp)
        trap    #1
        addq.l  #6,sp
        move.l  d0,old_stack
		
		bsr gen_sin
		
		; --- Initialisation de la palette ---
        move.w  #$000,$ff8240    ; Couleur 0 (Fond) : Noir
        move.w  #$777,$ff8242    ; Couleur 1 (Lignes) : Blanc

        ; --- Sauvegarde de l'ancienne adresse écran ---
        move.w  #2,-(sp)        ; Physbase
        trap    #14
        addq.l  #2,sp
        move.l  d0,old_screen

        ; --- Initialisation des buffers d'écran ---
        ; On aligne sur 256 octets (requis pour le Shifter)
        move.l  #screen_mem,d0
        add.l   #255,d0
        clr.b   d0
        move.l  d0,screen_1
        add.l   #32000,d0
        move.l  d0,screen_2

        ; --- Cache Mouse ---
        dc.w    $a00a

main_loop:
        bsr     wait_vbl

        ; --- Swap Buffers (Double Buffering) ---
        move.l  screen_1,d0
        move.l  screen_2,d1
        move.l  d1,screen_1     ; Affiche celui-ci
        move.l  d0,screen_2     ; Dessine sur celui-là

        ; --- XBIOS 5 - Setscreen ---
        move.w  #-1,-(sp)       ; Mode inchangé
        move.l  screen_1,-(sp)  ; Physbase (Visible)
        move.l  screen_2,-(sp)  ; Logbase (Calcul)
        move.w  #5,-(sp)
        trap    #14
        lea     12(sp),sp

        ; --- Nettoyage du buffer de travail ---
        move.l  screen_2,a0
        bsr     fast_cls

        ; --- Calcul et tracé du tunnel ---
        bsr     draw_tunnel

        ; --- Animation des variables ---
        addq.w  #4,rot_angle    ; Vitesse de rotation
        addq.w  #2,z_movement   ; Vitesse d'avance

        ; --- Test Sortie (Espace) ---
        move.w  #11,-(sp)       ; Cconis
        trap    #1
        addq.l  #2,sp
        tst.l   d0
        beq.s   main_loop

exit:
        ; --- Restauration ---
        move.w  #-1,-(sp)
        move.l  old_screen,-(sp)
        move.l  old_screen,-(sp)
        move.w  #5,-(sp)
        trap    #14
        lea     12(sp),sp

        dc.w    $a009           ; Show Mouse
        move.l  old_stack,-(sp)
        move.w  #32,-(sp)
        trap    #1
        addq.l  #6,sp

        clr.w   -(sp)
        trap    #1

; *************************************************************
; * ROUTINES DE CALCUL DU TUNNEL                              *
; *************************************************************

draw_tunnel:
        move.w  #12,d7          ; 12 segments de triangles
.loop_z:
        move.w  d7,d0
        lsl.w   #5,d0           ; Espacement Z
        add.w   z_movement,d0
        and.w   #511,d0         ; Boucle infinie
        
        move.w  #512,d1
        sub.w   d0,d1           ; D1 = Distance Z (profondeur)
        ble.s   .next_z

        ; Facteur de projection (256/Z)
        move.w  #16384,d2
        divu    d1,d2           ; D2 = Scale

        ; Rotation
        move.w  rot_angle,d3
        move.w  d7,d0
        lsl.w   #3,d0
        add.w   d0,d3           ; Twist du tunnel

        ; Point 1 (0°)
        bsr     get_vtx
        move.w  d4,p1_x
        move.w  d5,p1_y
        ; Point 2 (120° -> +170 sur 512)
        add.w   #170,d3
        bsr     get_vtx
        move.w  d4,p2_x
        move.w  d5,p2_y
        ; Point 3 (240° -> +170 sur 512)
        add.w   #170,d3
        bsr     get_vtx
        move.w  d4,p3_x
        move.w  d5,p3_y

        ; Tracé des 3 faces
        move.w  p1_x,d0
        move.w  p1_y,d1
        move.w  p2_x,d2
        move.w  p2_y,d3
        bsr     line_bresenham

        move.w  p2_x,d0
        move.w  p2_y,d1
        move.w  p3_x,d2
        move.w  p3_y,d3
        bsr     line_bresenham

        move.w  p3_x,d0
        move.w  p3_y,d1
        move.w  p1_x,d2
        move.w  p1_y,d3
        bsr     line_bresenham

.next_z:
        dbf     d7,.loop_z
        rts

get_vtx:
        and.w   #511,d3
        lea     sin_tab,a1
        move.w  (a1,d3.w*2),d4  ; Sin
        add.w   #128,d3         ; Cos (+90°)
        and.w   #511,d3
        move.w  (a1,d3.w*2),d5  ; Cos

        muls    d2,d4           ; Perspective X
        asl.l   #2,d4
        swap    d4
        add.w   #160,d4

        muls    d2,d5           ; Perspective Y
        asl.l   #2,d5
        swap    d5
        add.w   #100,d5
        rts

; *************************************************************
; * BRESENHAM OPTIMISE (BITPLANE 0)                           *
; *************************************************************

line_bresenham:
        ; Simple clipping (0-319, 0-199)
        cmp.w   #0,d0
        blt.s   .end
        cmp.w   #319,d0
        bgt.s   .end
        ; ... (Agréger clipping complet pour production)

        move.l  screen_2,a0
        sub.w   d0,d2           ; dX
        bpl.s   .dx_pos
        neg.w   d2
        move.w  #-1,d4          ; StepX
        bra.s   .calc_dy
.dx_pos: move.w  #1,d4
.calc_dy:
        sub.w   d1,d3           ; dY
        bpl.s   .dy_pos
        neg.w   d3
        move.w  #-1,d5          ; StepY
        bra.s   .init_bres
.dy_pos: move.w  #1,d5

.init_bres:
        move.w  d1,d6
        mulu    #160,d6
        move.w  d0,d7
        lsr.w   #4,d7
        lsl.w   #3,d7
        add.w   d7,d6
        add.l   d6,a0           ; Adresse du mot
        
        move.w  d0,d7
        and.w   #15,d7
        move.w  #$8000,d6
        lsr.w   d7,d6           ; Bit masque

        cmp.w   d2,d3
        bgt.s   .line_y

.line_x:
        move.w  d2,d7
        move.w  d2,d0
        lsr.w   #1,d0
.lp_x:  or.w    d6,(a0)
        sub.w   d3,d0
        bge.s   .no_y
        add.w   d2,d0
        tst.w   d5
        bmi.s   .y_up
        add.w   #160,a0
        bra.s   .no_y
.y_up:  sub.w   #160,a0
.no_y:  tst.w   d4
        bmi.s   .x_left
        ror.w   #1,d6
        bcc.s   .nx_x
        addq.l  #8,a0
        bra.s   .nx_x
.x_left: rol.w   #1,d6
        bcc.s   .nx_x
        subq.l  #8,a0
.nx_x:  dbf     d7,.lp_x
        rts

.line_y:
        move.w  d3,d7
        move.w  d3,d0
        lsr.w   #1,d0
.lp_y:  or.w    d6,(a0)
        sub.w   d2,d0
        bge.s   .no_x
        add.w   d3,d0
        tst.w   d4
        bmi.s   .xl_y
        ror.w   #1,d6
        bcc.s   .no_x
        addq.l  #8,a0
        bra.s   .no_x
.xl_y:  rol.w   #1,d6
        bcc.s   .no_x
        subq.l  #8,a0
.no_x:  tst.w   d5
        bmi.s   .yu_y
        add.w   #160,a0
        bra.s   .ny_y
.yu_y:  sub.w   #160,a0
.ny_y:  dbf     d7,.lp_y
.end:   rts

; *************************************************************
; * UTILS & DATA                                              *
; *************************************************************

wait_vbl:
        move.w  #37,-(sp)
        trap    #14
        addq.l  #2,sp
        rts

fast_cls:
        move.w  #1000-1,d0
        moveq   #0,d1
        move.l  d1,d2
        move.l  d1,d3
        move.l  d1,d4
        move.l  d1,d5
        move.l  d1,d6
        move.l  d1,a1
        move.l  d1,a2
.cl:    movem.l d1-d6/a1-a2,(a0)
        lea     32(a0),a0
        dbf     d0,.cl
        rts
		
; *************************************************************
; * GENERATION DE LA TABLE DE SINUS (Cercle de Minsky)        *
; * Remplit 512 mots (1 cycle complet)                        *
; *************************************************************

gen_sin:
        lea     sin_tab,a0
        move.w  #511,d7         ; 512 points
        move.w  #0,d0           ; Sinus initial (Y)
        move.w  #16384,d1       ; Cosinus initial (X)
        move.w  #201,d2         ; Pas de rotation (environ 2*PI/512 * 16384)

.loop:
        move.w  d0,(a0)+        ; Stocke le sinus
        
        ; Algorithme de Minsky :
        ; X = X - (Y * k) >> shift
        ; Y = Y + (X * k) >> shift
        
        move.w  d0,d3
        muls    d2,d3
        asl.l   #2,d3           ; Ajustement précision
        swap    d3
        sub.w   d3,d1           ; Nouveau Cosinus
        
        move.w  d1,d3
        muls    d2,d3
        asl.l   #2,d3
        swap    d3
        add.w   d3,d0           ; Nouveau Sinus
        
        dbf     d7,.loop
        rts
		

        SECTION DATA
rot_angle:  dc.w 0
z_movement: dc.w 0

; Table sinus (1 cycle = 512 entrées)
sin_tab:
        dc.w 0,1,3,4,6,7,9,10,12,13,15,16,18,19,21,22
        ; ... Note: Pour un code compact, générez cette table
        ; ou incluez un fichier binaire. Ici, dcb.w pour l'espace.
        dcb.w 512,0 

        SECTION BSS
old_stack:  ds.l 1
old_screen: ds.l 1
screen_1:   ds.l 1
screen_2:   ds.l 1
p1_x:       ds.w 1
p1_y:       ds.w 1
p2_x:       ds.w 1
p2_y:       ds.w 1
p3_x:       ds.w 1
p3_y:       ds.w 1
            ds.b 256
screen_mem: ds.b 64000+256


; Organisation de la Mémoire (Bitplanes) : 
;
; Sur Atari ST, l'image est stockée de manière entrelacée. 
; Ma routine de ligne calcule l'adresse (Y * 160) + (X / 16) * 8. 
; Le multiplicateur 8 vient du fait que chaque mot de 16 pixels est suivi des 3 autres plans de bits pour les couleurs. 
; Pour aller vite, on ne dessine que dans le Plan 0 (ce qui donne la couleur 1).

; Double Buffering XBIOS 5 : 
;
; Le programme utilise Setscreen pour dire au Shifter d'afficher un buffer pendant que le CPU calcule le tunnel dans le second. 
; Cela évite tout scintillement (flicker-free).

; Bresenham : La routine est optimisée pour minimiser les calculs dans la boucle. 
; On utilise des rotations de bits (ror.w / rol.w) et on ne met à jour l'adresse mémoire que lorsqu'on change de bloc de 16 pixels (addq.l #8, a0).

; Perspective 3D : 
; L'effet de tunnel est créé en divisant les coordonnées X/Y par la profondeur Z. Plus Z est petit, plus le triangle est grand à l'écran.

; Ajout clipping optionnel
; Clipping simple
;       cmp.w   #319,d0
;        bhi     .end     ; Si > 319 ou négatif (car bhi est non-signé)
;        cmp.w   #199,d1
;        bhi     .end
;        ; ... pareil pour d2, d3