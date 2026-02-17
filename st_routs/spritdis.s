; *************************************************************
; * 5 DISTORTED SPRITES DEMO - DEVPAC 68000 - ATARI ST        *
; * Pre-shifted sprites, PI1 palette, 3 bitplanes             *
; * Trajectoire Lissajous, masques pre-calcules, double buf.  *
; *************************************************************
;
; FICHIERS REQUIS (meme dossier que le .s) :
;   palette.pal  - 32 octets bruts (16 x word $0RGB)
;   sprite.bin   - 384 octets (3 plans * 32 lignes * 2 mots/ligne)
;   mask.bin     - 128 octets (1 plan * 32 lignes * 2 mots/ligne)
;
; EXTRACTION DEPUIS UN PI1 :
;   palette.pal  = octets 2..33 du .PI1 (sauter les 2 octets resolution)
;   sprite.bin   = zone graphique a partir de l'octet 34 du .PI1
;                  ré-encodée en [P0m0 P0m1 P1m0 P1m1 P2m0 P2m1] / ligne
;   mask.bin     = OR logique des 3 plans -> 1 plan 32x32, 2 mots/ligne
;
; ARCHITECTURE MEMOIRE PRECALCUL :
;   sprite_planes : 16 phases * 32 lignes * 6 mots = 6144 octets
;   mask_planes   : 16 phases * 32 lignes * 4 mots = 4096 octets
;   sin_table     : 512 mots  (Minsky, amplitude ~100px)
;   distort_table : 128 mots  (Minsky, amplitude ~12px)
;
; ECRAN ST LOW-RES (320x200, 4 plans, interleaved) :
;   1 ligne = 160 octets = 20 chunks de 8 octets
;   1 chunk = [P0w P1w P2w P3w] = 4 plans * 2 octets = 16 pixels
;
; *************************************************************

        OPT     O+,OW-
        OUTPUT  .TOS

        SECTION TEXT

; =============================================================
; ENTREE
; =============================================================
start:
        clr.l   -(sp)
        move.w  #32,-(sp)
        trap    #1
        addq.l  #6,sp
        move.l  d0,old_stack

        move.w  #2,-(sp)
        trap    #14
        addq.l  #2,sp
        move.l  d0,old_screen

        ; Alignement buffers video sur 256 octets
        move.l  #screen_mem,d0
        addi.l  #255,d0
        andi.b  #$00,d0
        move.l  d0,screen_1
        addi.l  #32000,d0
        move.l  d0,screen_2

        ; Effacement buffers
        move.l  screen_1,a0
        bsr     clr_screen
        move.l  screen_2,a0
        bsr     clr_screen

        ; Generation des tables et precalculs
        bsr     gen_sin_table       ; Table sinus 512 entrees
        bsr     gen_distort_table   ; Table distorsion 128 entrees
        bsr     precompute_all      ; Pre-shift sprites + masques
        bsr     load_palette        ; Palette depuis fichier PI1

        clr.w   sine_index
        clr.w   distort_index

; =============================================================
; BOUCLE PRINCIPALE
; =============================================================
main_loop:
        bsr     wait_vbl

        ; Swap double buffer
        move.l  screen_1,d0
        move.l  screen_2,d1
        move.l  d1,screen_1
        move.l  d0,screen_2

        move.w  #-1,-(sp)
        move.l  screen_1,-(sp)      ; Physique = visible
        move.l  screen_2,-(sp)      ; Logique  = dessin
        move.w  #5,-(sp)
        trap    #14
        lea     12(sp),sp

        ; Effacement buffer de dessin
        move.l  screen_2,a0
        bsr     clr_screen

        ; Mise a jour positions + dessin
        bsr     move_and_draw

        ; Avance indices globaux
        addq.w  #2,sine_index
        andi.w  #1022,sine_index
        addq.w  #2,distort_index
        andi.w  #254,distort_index

        ; Test sortie (ESPACE=$39, ESC=$01)
        btst    #0,$fffffc00.w
        beq.s   main_loop
        move.b  $fffffc02.w,d0
        cmpi.b  #$39,d0
        beq.s   do_exit
        cmpi.b  #$01,d0
        bne.s   main_loop

; =============================================================
; SORTIE PROPRE
; =============================================================
do_exit:
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
; * DEPLACEMENT ET DESSIN DES 5 SPRITES
; * Trajectoire de Lissajous : X=sin(t), Y=sin(2t)
; * Les 5 sprites sont espaces de 1/5 de la courbe
; *************************************************************
move_and_draw:
        movem.l d0-d7/a0-a6,-(sp)

        move.w  sine_index,d6       ; Position sur la courbe
        move.w  distort_index,d5    ; Phase de distorsion globale
        move.w  #4,d7               ; 5 sprites

.sp_loop:
        ; --- Calcul X = sin(t), centré sur 144 (plage 0..288) ---
        lea     sin_table,a0
        move.w  d6,d0
        andi.w  #1022,d0
        move.w  (a0,d0.w),d1        ; sin(t) ~ +/-100
        move.w  d1,d2
        asr.w   #2,d2
        add.w   d2,d1               ; +25% d'amplitude = +/-125
        addi.w  #144,d1             ; Centre : 319/2 - 16 = 144

        ; --- Calcul Y = sin(2t), centré sur 84 (plage 0..168) ---
        move.w  d6,d0
        lsl.w   #1,d0
        andi.w  #1022,d0
        move.w  (a0,d0.w),d2        ; sin(2t)
        asr.w   #1,d2               ; Amplitude /2 = +/-50
        addi.w  #84,d2              ; Centre

        ; --- Clamp X dans [0..288] (ecran 320, sprite 32px) ---
        cmpi.w  #0,d1
        bge.s   .cx_ok
        clr.w   d1
.cx_ok: cmpi.w  #288,d1
        ble.s   .cy_chk
        move.w  #288,d1

        ; --- Clamp Y dans [0..168] ---
.cy_chk:
        cmpi.w  #0,d2
        bge.s   .cy_ok
        clr.w   d2
.cy_ok: cmpi.w  #168,d2
        ble.s   .do_draw
        move.w  #168,d2

.do_draw:
        ; Dessin du sprite courant
        bsr     draw_sprite

        ; Espacement 1/5 de la courbe (1024/5 ~ 205)
        addi.w  #205,d6
        andi.w  #1022,d6
        ; Phase de distorsion decalee par sprite
        addi.w  #51,d5
        andi.w  #254,d5

        dbf     d7,.sp_loop

        movem.l (sp)+,d0-d7/a0-a6
        rts


; *************************************************************
; * DESSIN D'UN SPRITE AVEC PRE-SHIFT ET DISTORSION
; *
; * Entrees : D1.w = X (0..319)
; *            D2.w = Y (0..199)
; *            D5.w = phase distorsion (index distort_table)
; *
; * Format ecran ST interleaved par chunk de 16 pixels :
; *   Offset +0  : Plan0 mot (pixels 0-15)
; *   Offset +2  : Plan1 mot
; *   Offset +4  : Plan2 mot
; *   Offset +6  : Plan3 mot  (Plan3 = 0 = couleur de fond)
; *   Offset +8  : Plan0 mot suivant (pixels 16-31)
; *   ... etc.
; *
; * Le sprite 32px wide occupe 2 mots par plan, soit 2 chunks.
; * Avec le pre-shift, un 3eme mot de debordement peut apparaitre.
; *************************************************************
draw_sprite:
        movem.l d0-d7/a0-a6,-(sp)

        ; Phase pre-shift = bits 3..0 de X (0..15)
        move.w  d1,d3
        andi.w  #$0F,d3

        ; Adresse de base dans le buffer de dessin
        move.l  screen_2,a0
        mulu.w  #160,d2             ; Y * 160 octets/ligne
        add.l   d2,a0
        move.w  d1,d0
        lsr.w   #4,d0               ; Chunk X = X/16
        lsl.w   #3,d0               ; Chunk * 8 octets (taille chunk interleaved)
        add.w   d0,a0               ; A0 = adresse destination

        ; Pointeur sprite pre-shifte pour cette phase
        ; Layout : [phase][ligne][P0m0][P0m1][P1m0][P1m1][P2m0][P2m1]
        ; 6 mots = 12 octets par ligne, 32 lignes = 384 octets par phase
        lea     sprite_planes,a2
        move.w  d3,d0
        mulu.w  #384,d0
        add.l   d0,a2

        ; Pointeur masque pre-shifte
        ; Layout : [phase][ligne][M0][M1][M_overflow][pad]
        ; 4 mots = 8 octets par ligne, 32 lignes = 256 octets par phase
        lea     mask_planes,a3
        move.w  d3,d0
        mulu.w  #256,d0
        add.l   d0,a3

        ; Table de distorsion
        lea     distort_table,a1

        ; Boucle sur les 32 lignes du sprite
        move.w  #31,d7

.draw_line:
        ; Offset de distorsion pour cette ligne (en pixels)
        move.w  d5,d0
        andi.w  #254,d0
        move.w  (a1,d0.w),d4        ; d4 = decalage -12..+12 pixels

        ; Conversion : pixels -> octets (par chunk de 16px = 8 octets)
        ; On limite a +/-1 chunk pour eviter les sorties d'ecran
        move.w  d4,d0
        asr.w   #3,d0               ; /8 -> valeur -1, 0 ou +1
        lsl.w   #3,d0               ; * 8 = octets deplacement
        cmpi.w  #-8,d0
        bge.s   .dok_lo
        move.w  #-8,d0
.dok_lo:
        cmpi.w  #8,d0
        ble.s   .dok_hi
        move.w  #8,d0
.dok_hi:
        ; Adresse effective avec distorsion
        move.l  a0,a5
        add.w   d0,a5

        ; Chargement masques (3 mots : chunk0, chunk1, debordement)
        move.w  (a3)+,d0            ; Masque chunk 0
        move.w  (a3)+,d1            ; Masque chunk 1
        move.w  (a3)+,d2            ; Masque debordement
        addq.l  #2,a3               ; Padding

        ; NOT masque -> trous dans le fond aux endroits opaques du sprite
        not.w   d0
        not.w   d1
        not.w   d2

        ; AND masque sur les 3 chunks * 3 plans
        ; Chunk 0 (offset 0) : Plans 0,1,2 aux offsets 0,2,4
        and.w   d0,0(a5)
        and.w   d0,2(a5)
        and.w   d0,4(a5)
        ; Chunk 1 (offset 8) : Plans 0,1,2 aux offsets 8,10,12
        and.w   d1,8(a5)
        and.w   d1,10(a5)
        and.w   d1,12(a5)
        ; Debordement (offset 16)
        and.w   d2,16(a5)
        and.w   d2,18(a5)
        and.w   d2,20(a5)

        ; Chargement donnees sprite : [P0m0 P0m1 P1m0 P1m1 P2m0 P2m1]
        move.w  (a2)+,d0            ; Plan0, chunk0
        move.w  (a2)+,d1            ; Plan0, chunk1
        move.w  (a2)+,d2            ; Plan1, chunk0
        move.w  (a2)+,d3            ; Plan1, chunk1
        move.w  (a2)+,d4            ; Plan2, chunk0
        move.w  (a2)+,d6            ; Plan2, chunk1

        ; OR sprite sur fond troue
        or.w    d0,0(a5)
        or.w    d1,8(a5)
        or.w    d2,2(a5)
        or.w    d3,10(a5)
        or.w    d4,4(a5)
        or.w    d6,12(a5)

        ; Ligne suivante
        add.w   #160,a0
        addq.w  #2,d5
        andi.w  #254,d5

        dbf     d7,.draw_line

        movem.l (sp)+,d0-d7/a0-a6
        rts


; *************************************************************
; * PRECALCUL : PRE-SHIFT SPRITES + MASQUES
; *
; * Pour chaque phase P (0..15) :
; *   Sprite : [P0m0 P0m1 | P1m0 P1m1 | P2m0 P2m1] -> shift P bits
; *            Assemblee en longword, lsr.l P, re-decomposee
; *   Masque : [Mm0 Mm1] -> shift P bits + calcul mot debordement
; *
; * Shift par assemblage longword (methode sans erreur) :
; *   [mot_haut][mot_bas] = 2 mots 16 bits
; *   lsl.l #P donne [mot_haut >> P | bits entrant] [mot_bas << P]
; *   On assemble : tmp.l = (mot_haut << 16) | mot_bas
; *   Puis : lsr.l #P, tmp
; *   mot_haut_shift = swap(tmp).w
; *   mot_bas_shift  = tmp.w
; *************************************************************
precompute_all:
        movem.l d0-d7/a0-a6,-(sp)

        ; ==== PRE-SHIFT SPRITES ====
        move.w  #15,d7              ; Phases 0..15

.ph_sp: move.w  #15,d5
        sub.w   d7,d5               ; d5 = phase courante (0..15)

        move.l  d5,d0
        mulu.w  #384,d0
        lea     sprite_planes,a5
        add.l   d0,a5               ; Destination phase d5

        move.w  #31,d6              ; Lignes 0..31

.ln_sp: ; Calcul adresse source : ligne (31-d6) * 12 octets
        move.w  #31,d0
        sub.w   d6,d0
        mulu.w  #12,d0
        lea     sprite_raw,a0
        add.l   d0,a0

        ; 3 plans : chacun = [m0][m1] -> 2 mots
        move.w  #2,d4               ; Plans 0,1,2 (dbf 2..0)

.pl_sp: move.w  (a0)+,d0            ; Mot haut
        move.w  (a0)+,d1            ; Mot bas
        ; Assemblage longword
        swap    d0                  ; d0 = [mot_haut | ????]
        move.w  d1,d0               ; d0.l = [mot_haut << 16 | mot_bas]
        ; Decalage
        lsr.l   d5,d0
        ; Decomposition
        swap    d0
        move.w  d0,(a5)+            ; Mot haut post-shift
        swap    d0
        move.w  d0,(a5)+            ; Mot bas post-shift

        dbf     d4,.pl_sp
        dbf     d6,.ln_sp
        dbf     d7,.ph_sp

        ; ==== PRE-SHIFT MASQUES ====
        move.w  #15,d7

.ph_mk: move.w  #15,d5
        sub.w   d7,d5

        move.l  d5,d0
        mulu.w  #256,d0
        lea     mask_planes,a6
        add.l   d0,a6

        move.w  #31,d6

.ln_mk: ; Source : ligne (31-d6) * 4 octets
        move.w  #31,d0
        sub.w   d6,d0
        mulu.w  #4,d0
        lea     sprite_mask_raw,a0
        add.l   d0,a0

        move.w  (a0)+,d0            ; Mot masque haut
        move.w  (a0)+,d1            ; Mot masque bas

        ; Assemblage + shift
        swap    d0
        move.w  d1,d0               ; d0.l = [m_haut << 16 | m_bas]
        lsr.l   d5,d0

        swap    d0
        move.w  d0,(a6)+            ; Masque mot 0 post-shift
        swap    d0
        move.w  d0,(a6)+            ; Masque mot 1 post-shift

        ; Mot de debordement = bits de m_bas sortis par la droite lors du shift
        ; Formule : overflow = m_bas << (16 - shift), si shift > 0
        clr.w   d2
        tst.w   d5
        beq.s   .no_ov
        move.w  d1,d2
        move.w  #16,d3
        sub.w   d5,d3               ; 16 - shift
        lsl.w   d3,d2               ; Bits de debordement
.no_ov: move.w  d2,(a6)+            ; Mot debordement
        clr.w   (a6)+               ; Padding (aligne sur 4 mots par ligne)

        dbf     d6,.ln_mk
        dbf     d7,.ph_mk

        movem.l (sp)+,d0-d7/a0-a6
        rts


; *************************************************************
; * TABLE SINUS - Oscillateur de Minsky
; * 512 entrees, valeurs signees, amplitude ~100 pixels
; * Formule : Y(n+1) = Y(n) - X(n)/128
; *            X(n+1) = X(n) + Y(n+1)/128
; * Avec Y(0)=0, X(0)=A*128 -> amplitude A
; *************************************************************
gen_sin_table:
        movem.l d0-d7/a0,-(sp)
        lea     sin_table,a0
        clr.w   d0                  ; Y=0
        move.w  #12800,d1           ; X=100*128
        move.w  #511,d7
.sl:    move.w  d1,d2
        asr.w   #7,d2
        sub.w   d2,d0               ; Y -= X/128
        move.w  d0,d2
        asr.w   #7,d2
        add.w   d2,d1               ; X += Y/128
        move.w  d0,d2
        asr.w   #7,d2               ; Normalise /128
        move.w  d2,(a0)+
        dbf     d7,.sl
        movem.l (sp)+,d0-d7/a0
        rts


; *************************************************************
; * TABLE DISTORSION - Minsky, amplitude ~12px
; * 128 entrees, frequence plus rapide (diviseur 32)
; *************************************************************
gen_distort_table:
        movem.l d0-d7/a0,-(sp)
        lea     distort_table,a0
        clr.w   d0
        move.w  #3072,d1            ; 12*256
        move.w  #127,d7
.dl:    move.w  d1,d2
        asr.w   #5,d2
        sub.w   d2,d0
        move.w  d0,d2
        asr.w   #5,d2
        add.w   d2,d1
        move.w  d0,d2
        asr.w   #8,d2               ; Normalise -> +/-12 pixels
        move.w  d2,(a0)+
        dbf     d7,.dl
        movem.l (sp)+,d0-d7/a0
        rts


; *************************************************************
; * CHARGEMENT PALETTE
; * Copie les 16 couleurs du fichier vers les registres palette
; *************************************************************
load_palette:
        movem.l d0/a0-a1,-(sp)
        lea     pi1_palette,a0
        lea     $ff8240.w,a1
        move.w  #15,d7
.pl:    move.w  (a0)+,(a1)+
        dbf     d7,.pl
        movem.l (sp)+,d0/a0-a1
        rts


; *************************************************************
; * ATTENTE VBL (Xbios 37)
; *************************************************************
wait_vbl:
        move.w  #37,-(sp)
        trap    #14
        addq.l  #2,sp
        rts


; *************************************************************
; * EFFACEMENT ECRAN RAPIDE (32000 octets)
; * A0 = adresse ecran
; * 4 longwords par iteration = 16 octets
; * 2000 iterations * 16 = 32000 octets
; *************************************************************
clr_screen:
        movem.l d0-d1/d7,-(sp)
        moveq   #0,d0
        moveq   #0,d1
        move.w  #1999,d7
.cl:    move.l  d0,(a0)+
        move.l  d1,(a0)+
        move.l  d0,(a0)+
        move.l  d1,(a0)+
        dbf     d7,.cl
        movem.l (sp)+,d0-d1/d7
        rts


; *************************************************************
; * SECTION DATA
; *************************************************************
        SECTION DATA
        even

sine_index:     dc.w    0
distort_index:  dc.w    0

        even
pi1_palette:    INCBIN  "palette.pal"       ; 32 octets (16 x word $0RGB)

        even
sprite_raw:     INCBIN  "sprite.bin"        ; 384 octets (3 plans * 32 lignes * 4o)

        even
sprite_mask_raw: INCBIN "mask.bin"          ; 128 octets (1 plan * 32 lignes * 4o)


; *************************************************************
; * SECTION BSS
; *************************************************************
        SECTION BSS
        even

old_stack:      ds.l    1
old_screen:     ds.l    1
screen_1:       ds.l    1
screen_2:       ds.l    1

        even
sin_table:      ds.w    512             ; 1024 octets

        even
distort_table:  ds.w    128             ; 256 octets

        even
sprite_planes:  ds.b    6144            ; 16 phases * 384 octets

        even
mask_planes:    ds.b    4096            ; 16 phases * 256 octets

        even
screen_mem:     ds.b    64256           ; 2 * 32000 + 256 alignement

        END     start


; Précalculs au démarrage
; La routine precompute_all génère les 16 phases de pre-shift pour sprites et masques. 
; La méthode clé : assembler les deux mots d'une ligne en un long, faire un seul lsr.l #phase,d0, puis re-séparer les deux mots. 
; C'est la façon propre sur 68000 sans multiplications de shift. Le mot de débordement (overflow quand le sprite sort du chunk courant) est capturé avec m_bas << (16 - phase).
; Masques — stockés en "positif" (1 = opaque), puis NOT au moment du dessin pour le AND sur le fond. 
; Trois mots par ligne : chunk0, chunk1, débordement.
; Dessin — pour chaque sprite, on calcule le chunk de destination, puis pour chaque ligne on applique la distorsion (décalage +/-8 octets max), 
; le AND masque sur les 3 plans × 3 chunks, puis le OR des données sprite.
; Trajectoire de Lissajous — X = sin(t), Y = sin(2t), les 5 sprites espacés de 1/5 de la table (205 sur 1024 entrées), avec phase de distorsion décalée de 51 entre chaque.
; Fichiers à préparer :
; palette.pal (32 octets bruts depuis le PI1 à l'offset 2), sprite.bin (3 plans, 32 lignes, 2 mots par plan/ligne = 384 octets), mask.bin (OR des 3 plans, 1 plan, 32 lignes = 128 octets).
