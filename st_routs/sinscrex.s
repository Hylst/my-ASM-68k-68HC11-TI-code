; ***********************************************************************
; * SINUS SCROLLTEXT + RASTERS - ATARI ST STF/STE                      *
; * Assembleur : DevPack / Profi-Ass (68000)                            *
; *                                                                     *
; * FONCTIONNALITÉS :                                                   *
; *  - Scroll horizontal pixel-par-pixel (sinus, 2 harmoniques)        *
; *  - Fonte bitmap 16x16, 47 glyphes (A-Z + chiffres + ponctu.)       *
; *  - Pré-décalage sur 16 phases (PRESHIFTED_FONT en BSS)             *
; *  - Rasters couleur ligne par ligne via Timer B (dégradé arc-en-ciel)*
; *  - Double buffering (scr_work / scr_show échangés chaque VBL)      *
; *  - Effacement efficace de la zone de rendu uniquement               *
; *  - Scroll ROXL chaîné, rendu MOVE.L déroulé (REPT)                 *
; *                                                                     *
; * POLICE PI1 (optionnel) :                                            *
; *  Décommenter le bloc INCBIN en bas de fichier pour utiliser         *
; *  une police bitmap importée depuis un fichier PI1 Degas Elite.      *
; *  Le PI1 doit être 320px de large, format ST Low (4 plans).          *
; *  Layout : 20 chars/ligne, 3 lignes utilisées.                       *
; *  Les 34 premiers octets (header) sont skippés à l'incbin.           *
; *  La routine gen_preshifted_font extrait le plan 0 si PI1_FONT=1.    *
; ***********************************************************************

        output  sinus.tos

;=======================================================================
; CONSTANTES GLOBALES
;=======================================================================

SCREEN_W        equ 320
SCREEN_H        equ 200
SCREEN_BYTES    equ 32000           ; 1 bitplane : 320*200/8

; Police
FONT_W          equ 16
FONT_H          equ 16
FONT_CHARS      equ 47              ; A-Z=26, espace=1, spéciaux=10, 0-9=10
FONT_CHARSIZE   equ FONT_H*2       ; octets par glyphe (16 lignes * 1 word)
CHARS_PER_ROW   equ 20             ; 320px / 16px

; Pré-décalage
NUM_PRESHIFTS   equ 16             ; une table par pixel de décalage (0..15)
PSHIFT_CHARSIZE equ FONT_H*4      ; 4 octets (1 long = 2 words) par ligne de char
PSHIFT_PHSIZE   equ FONT_CHARS*PSHIFT_CHARSIZE  ; taille d'une phase complète

; Table sinus
SINE_ENTRIES    equ 512
SINE_BYTEMASK   equ (SINE_ENTRIES*2)-2  ; masque AND pour index word cyclique

; Paramètres esthétiques du scroller
SCROLL_YBASE    equ 92              ; Y central de la bande
SINE_AMPL1      equ 54             ; amplitude sinus 1 (pixels)
SINE_AMPL2      equ 26             ; amplitude sinus 2 (harmonique)
SINE_STEP       equ 4              ; incrément sinus par ligne (distorsion)
GLOBAL_STEP     equ 3              ; incrément global par frame (vitesse)

; Zone de rendu (avec marges pour les dépassements sinus)
RZONE_TOP       equ SCROLL_YBASE - SINE_AMPL1 - SINE_AMPL2 - 2
RZONE_BOT       equ SCROLL_YBASE + FONT_H + SINE_AMPL1 + SINE_AMPL2 + 2
RZONE_LINES     equ RZONE_BOT - RZONE_TOP

; Buffer scroll (320px + 16px de garde = 336px = 21 words)
SBUF_WORDS      equ 21
SBUF_BYTES      equ SBUF_WORDS*2   ; 42 octets par ligne

; Rasters
RASTER_COUNT    equ 32             ; nombre de changements couleur / frame

; Nombre de words/line dans l'écran 1 plan
SCR_WORDS_LINE  equ SCREEN_W/16   ; = 20 words
SCR_BYTES_LINE  equ SCR_WORDS_LINE*2 ; = 40 octets

;=======================================================================
; MODE UTILISATION PI1 EXTERNE : mettre à 1 si incbin actif, 0 sinon
;=======================================================================
PI1_FONT        equ 0              ; 0 = fonte embarquée, 1 = fonte PI1 incbinée

;=======================================================================
; SECTION CODE
;=======================================================================
        SECTION TEXT

;-----------------------------------------------------------------------
; POINT D'ENTRÉE
;-----------------------------------------------------------------------
start:
        ; Passe en mode superviseur
        clr.l   -(sp)
        move.w  #$20,-(sp)
        trap    #1
        addq.l  #6,sp
        move.l  d0,old_ssp

        ; Sauvegarde pointeur écran actuel
        move.w  #2,-(sp)
        trap    #14
        addq.l  #2,sp
        move.l  d0,old_scr_ptr

        ; Calcule adresse écran 1 (work) aligné 256 octets
        move.l  #screen_mem,d0
        addi.l  #255,d0
        andi.l  #$FFFFFF00,d0
        move.l  d0,scr_work

        ; Calcule adresse écran 2 (show) juste après, aligné 256
        addi.l  #SCREEN_BYTES+255,d0
        andi.l  #$FFFFFF00,d0
        move.l  d0,scr_show

        ; Efface les deux écrans
        move.l  scr_work,a0
        bsr     clr_screen
        move.l  scr_show,a0
        bsr     clr_screen

        ; Charge palette
        bsr     do_palette

        ; Pointe le Shifter sur scr_show
        bsr     setscr

        ; Génère table sinus
        bsr     gen_sine

        ; Génère tables de pré-décalage
        bsr     gen_preshift

        ; Init variables
        clr.w   sx_sub              ; sous-pixel (0..15)
        clr.w   sine_ph             ; phase sinus globale
        move.l  #scroll_text,scr_ptr

        ; Efface scroll_buf
        lea     scroll_buf,a0
        move.w  #(SBUF_WORDS*FONT_H)-1,d7
.sbclr: clr.w   (a0)+
        dbf     d7,.sbclr

        ; Installe interruptions
        move.w  sr,old_sr
        move.l  $70.w,old_vbl
        move.l  $120.w,old_tb

        move.w  #$2700,sr
        move.l  #vbl_isr,$70.w
        move.l  #timerb_isr,$120.w
        bset    #0,$ffffa07.w       ; IERB bit0 enable Timer B
        bset    #0,$ffffa13.w       ; IMRB bit0 mask Timer B
        move.w  #$2300,sr

;-----------------------------------------------------------------------
; BOUCLE PRINCIPALE
;-----------------------------------------------------------------------
mainlp:
        stop    #$2300              ; synchro VBL (économise le CPU)

        ; Double buffering : swap
        move.l  scr_show,a0
        move.l  scr_work,a1
        move.l  a1,scr_show
        move.l  a0,scr_work
        bsr     setscr              ; repointe Shifter sur nouveau scr_show

        ; Efface zone de rendu dans scr_work
        bsr     clr_rzone

        ; Avance scroll d'1 pixel, peint char si besoin
        bsr     do_scroll

        ; Rendu sinus dans scr_work
        bsr     render

        ; Avance phase sinus globale
        move.w  sine_ph,d0
        addi.w  #GLOBAL_STEP*2,d0
        andi.w  #SINE_BYTEMASK,d0
        move.w  d0,sine_ph

        ; Test touche (ESPACE = scan $39 pour quitter)
        btst    #0,$ffffc00.w       ; registre ACIA (bit 0 = data ready)
        beq.s   mainlp
        move.b  $ffffc02.w,d0
        cmpi.b  #$39,d0
        bne.s   mainlp

;-----------------------------------------------------------------------
; SORTIE PROPRE
;-----------------------------------------------------------------------
quitprog:
        move.w  #$2700,sr
        move.l  old_vbl,$70.w
        move.l  old_tb,$120.w
        clr.b   $ffffa1b.w          ; stop Timer B
        bclr    #0,$ffffa07.w
        bclr    #0,$ffffa13.w
        move.w  old_sr,sr

        ; Efface écran et fond noir
        move.l  scr_show,a0
        bsr     clr_screen
        moveq   #0,d0
        lea     $ffff8240.w,a0
        move.w  #15,d7
.blk:   move.w  d0,(a0)+
        dbf     d7,.blk

        ; Retour user
        move.l  old_ssp,-(sp)
        move.w  #$20,-(sp)
        trap    #1
        addq.l  #6,sp
        clr.w   -(sp)
        trap    #1

;=======================================================================
; INTERRUPTION VBL
;=======================================================================
vbl_isr:
        movem.l d0/a0,-(sp)
        clr.b   $ffffa1b.w          ; stop Timer B (reset)

        ; Fond noir immédiat (avant tout raster)
        clr.w   $ffff8240.w

        ; Initialise le pointeur et compteur rasters
        move.l  #raster_tab,rst_ptr
        clr.w   rst_cnt

        ; Lance Timer B : attend RZONE_TOP lignes depuis le début du frame
        ; puis se déclenche chaque HBL
        move.b  #RZONE_TOP,$ffffa21.w
        move.b  #8,$ffffa1b.w       ; mode : décrémente sur HBL

        movem.l (sp)+,d0/a0
        rte

;=======================================================================
; INTERRUPTION TIMER B (HBL raster)
;=======================================================================
timerb_isr:
        bclr    #0,$ffffa0f.w       ; acknowledge Timer B (clear ISRB)
        movem.l d0/a0,-(sp)

        move.w  rst_cnt,d0
        cmpi.w  #RASTER_COUNT,d0
        bge.s   .rstop

        ; Change couleur 1 (encre = couleur du texte)
        move.l  rst_ptr,a0
        move.w  (a0)+,$ffff8242.w
        move.l  a0,rst_ptr
        addq.w  #1,rst_cnt

        ; Réarme pour la ligne suivante
        move.b  #1,$ffffa21.w
        bra.s   .rdone

.rstop: clr.b   $ffffa1b.w          ; plus de rasters, stop Timer B
.rdone:
        movem.l (sp)+,d0/a0
        rte

;=======================================================================
; SETSCR : pointe le Shifter Atari sur scr_show
;=======================================================================
setscr:
        move.l  scr_show,d0
        lsr.l   #8,d0
        move.b  d0,$ffff8203.w      ; adr moyenne
        lsr.l   #8,d0
        move.b  d0,$ffff8201.w      ; adr haute
        rts

;=======================================================================
; DO_PALETTE : charge 16 couleurs depuis font_palette
;=======================================================================
do_palette:
        lea     font_palette,a0
        lea     $ffff8240.w,a1
        move.w  #15,d7
.lp:    move.w  (a0)+,(a1)+
        dbf     d7,.lp
        rts

;=======================================================================
; CLR_SCREEN : efface SCREEN_BYTES octets à partir de a0
; Utilise MOVEM.L 8 registres = 32 octets par itération
;=======================================================================
clr_screen:
        movem.l d0-d7,-(sp)
        moveq   #0,d0
        moveq   #0,d1
        moveq   #0,d2
        moveq   #0,d3
        moveq   #0,d4
        moveq   #0,d5
        moveq   #0,d6
        moveq   #0,d7
        move.w  #(SCREEN_BYTES/32)-1,a1
.cl:    movem.l d0-d7,(a0)
        lea     32(a0),a0
        dbf     a1,.cl
        movem.l (sp)+,d0-d7
        rts

;=======================================================================
; CLR_RZONE : efface uniquement la zone de rendu dans scr_work
; En 1 plan, 1 ligne = 40 octets (20 words, 10 longs)
; On déroulé 10 CLR.L par ligne avec REPT
;=======================================================================
clr_rzone:
        movem.l d7/a0-a1,-(sp)
        move.l  scr_work,a0
        ; Avance jusqu'à la ligne RZONE_TOP
        move.w  #RZONE_TOP,d7
        mulu    #SCR_BYTES_LINE,d7
        adda.l  d7,a0
        ; Efface RZONE_LINES lignes
        move.w  #RZONE_LINES-1,d7
.czl:
        REPT    10                  ; 10 CLR.L = 40 octets = 1 ligne 1plan
        clr.l   (a0)+
        ENDR
        dbf     d7,.czl
        movem.l (sp)+,d7/a0-a1
        rts

;=======================================================================
; GEN_SINE : génère sine_table[512] valeurs word signées
; Algorithme : Minsky circle en fixpoint 32 bits
;   amplitude = SINE_AMPL1 pixels
;   eps = 2*sin(pi/512) ≈ 0.012272 → fixpoint: round(0.012272 * 65536) = 804
;=======================================================================
gen_sine:
        movem.l d0-d4/a0,-(sp)
        lea     sine_table,a0

        ; x = SINE_AMPL1 * 65536 (fixpoint), y = 0
        move.l  #SINE_AMPL1*65536,d0
        clr.l   d1
        move.l  #804,d2             ; epsilon fixpoint

        move.w  #SINE_ENTRIES-1,d7
.gs:
        ; Stocke y >> 16 comme valeur sinus courante
        move.l  d1,d3
        asr.l   #8,d3
        asr.l   #8,d3               ; d3 = y / 65536 (signé)
        move.w  d3,(a0)+

        ; x -= eps * (y >> 16)
        move.w  d3,d4               ; d4.w = y >> 16
        muls    d2,d4               ; d4.l = eps * (y>>16)
        sub.l   d4,d0

        ; y += eps * (x >> 16) [x déjà mis à jour]
        move.l  d0,d3
        asr.l   #8,d3
        asr.l   #8,d3
        move.w  d3,d4
        muls    d2,d4
        add.l   d4,d1

        dbf     d7,.gs
        movem.l (sp)+,d0-d4/a0
        rts

;=======================================================================
; GEN_PRESHIFT : génère les 16 tables de pré-décalage
;
; Pour chaque phase p (0..15) et chaque char c (0..FONT_CHARS-1) :
;   - Lit FONT_H words depuis font_data (ou PI1 si PI1_FONT=1)
;   - Décale le long [word:0000] de p bits vers la droite
;   - Stocke le long résultat dans preshifted_font
;
; Structure preshifted_font (en BSS) :
;   [phase 0] [char 0] [line 0..15] = 16 longs
;   [phase 0] [char 1] ...
;   ...
;   [phase 15] [char 46] [line 0..15]
; Total : 16 * 47 * 16 * 4 = 47872 octets
;=======================================================================
gen_preshift:
        movem.l d0-d7/a0-a3,-(sp)
        lea     preshifted_font,a2  ; destination

        moveq   #0,d6               ; phase 0..15
.gph:
        moveq   #0,d5               ; char 0..46
.gch:
        ; Adresse du char dans font_data
        move.w  d5,d0
        mulu    #FONT_CHARSIZE,d0
        lea     font_data,a1
        adda.l  d0,a1               ; a1 = premier word du char

        move.w  #FONT_H-1,d7        ; 16 lignes
.gln:
        ; Lit 1 word (16px), place en bits 31..16 du long
        move.w  (a1)+,d0
        swap    d0
        clr.w   d0                  ; d0.l = word:0000 (bits 31..16 = pixels)

        ; Décalage logique droit de d6 bits (phase 0 = intact, phase N = N shifts)
        move.w  d6,d1
        beq.s   .gns               ; phase 0 : aucun décalage
        subq.w  #1,d1              ; DBF boucle N+1 fois : on passe N-1 pour N tours
.gsh:   lsr.l   #1,d0
        dbf     d1,.gsh
.gns:   move.l  d0,(a2)+

        dbf     d7,.gln

        addq.w  #1,d5
        cmp.w   #FONT_CHARS,d5
        blt.s   .gch

        addq.w  #1,d6
        cmp.w   #NUM_PRESHIFTS,d6
        blt.s   .gph

        movem.l (sp)+,d0-d7/a0-a3
        rts

;=======================================================================
; DO_SCROLL : avance le scroller d'1 pixel à gauche
; 1. Scrolle scroll_buf (16 lignes * 21 words) de 1 bit avec ROXL chaîné
; 2. Incrémente le sous-pixel ; si retombé à 0, peint le char suivant
;=======================================================================
do_scroll:
        movem.l d1/a0,-(sp)

        ; Scroll ROXL chaîné sur chaque ligne
        lea     scroll_buf,a0
        move.w  #FONT_H-1,d1
.sln:
        andi    #$FEFF,ccr          ; clear bit X du CCR
        REPT    SBUF_WORDS          ; 21 ROXL.W consécutifs = scroll 1 bit
        roxl.w  #1,(a0)+
        ENDR
        dbf     d1,.sln

        ; Sous-pixel
        move.w  sx_sub,d1
        addq.w  #1,d1
        andi.w  #15,d1
        move.w  d1,sx_sub
        bne.s   .scdone

        ; 16 pixels scrollés : ajoute le prochain caractère
        bsr     paint_char

.scdone:
        movem.l (sp)+,d1/a0
        rts

;=======================================================================
; PAINT_CHAR : lit le prochain char du texte, peint dans la colonne droite
; du scroll_buf en utilisant la table pré-décalée (phase 0 ici).
; Le char est placé dans les 2 derniers words de chaque ligne (long à pos 19-20).
;=======================================================================
paint_char:
        movem.l d0-d2/a0-a2,-(sp)

        ; Lit le prochain char ASCII
        move.l  scr_ptr,a0
        move.b  (a0),d0
        bne.s   .pcgot
        ; Fin de chaîne : retour au début
        move.l  #scroll_text,a0
        move.b  (a0),d0
.pcgot:
        addq.l  #1,a0               ; avance le pointeur
        move.l  a0,scr_ptr          ; mémorise

        ; ASCII -> index fonte
        bsr     a2idx               ; d0.b -> d0.w (index ou -1)
        cmpi.w  #-1,d0
        beq.s   .pcdone             ; index -1 = char non géré = espace (saut)
        cmp.w   #FONT_CHARS,d0
        bge.s   .pcdone             ; sécurité

        ; Adresse dans preshifted_font, phase = sx_sub (0..15)
        ; Juste avant d'appeler paint_char, sx_sub vient d'être remis à 0,
        ; donc la phase effective est 0 (le char arrive en bord droit intact).
        ; L'effet de décalage progressif est assuré par le ROXL du scroll.
        mulu    #PSHIFT_CHARSIZE,d0  ; offset char (phase 0)
        lea     preshifted_font,a1
        adda.l  d0,a1

        ; Position destination : long à l'offset (SBUF_WORDS-2)*2 dans chaque ligne
        ; = les 2 derniers words du buffer (bord droit)
        lea     scroll_buf,a2
        adda.w  #(SBUF_WORDS-2)*2,a2 ; pointe sur l'avant-dernier word, ligne 0

        move.w  #FONT_H-1,d2
.pclp:
        move.l  (a1)+,d0            ; long pré-shifté (word_L:word_R)
        or.l    d0,(a2)             ; OR dans les 2 derniers words de la ligne
        adda.w  #SBUF_BYTES,a2      ; passe à la ligne suivante
        dbf     d2,.pclp

.pcdone:
        movem.l (sp)+,d0-d2/a0-a2
        rts

;=======================================================================
; A2IDX : convertit code ASCII en index de fonte
; Entrée : d0.w = code ASCII
; Sortie : d0.w = index (0..46) ou -1 si non géré
;=======================================================================
a2idx:
        andi.w  #$00FF,d0

        ; Minuscules -> majuscules
        cmp.w   #'a',d0
        blt.s   .a2n_lo
        cmp.w   #'z',d0
        bgt.s   .a2n_lo
        subi.w  #32,d0
.a2n_lo:
        ; A..Z -> 0..25
        cmp.w   #'A',d0
        blt.s   .a2n_az
        cmp.w   #'Z',d0
        bgt.s   .a2n_az
        subi.w  #'A',d0
        rts
.a2n_az:
        ; 0..9 -> 37..46
        cmp.w   #'0',d0
        blt.s   .a2n_dig
        cmp.w   #'9',d0
        bgt.s   .a2n_dig
        subi.w  #'0',d0
        addi.w  #37,d0
        rts
.a2n_dig:
        ; Espace -> 26
        cmp.w   #' ',d0
        bne.s   .a2n_sp
        move.w  #26,d0
        rts
.a2n_sp:
        ; Table spéciaux : paires (ascii,index) terminées par $FF
        lea     sp_lut,a1
.a2slp: move.b  (a1)+,d1
        bmi.s   .a2nf               ; $FF = fin
        cmp.w   d1,d0
        beq.s   .a2sf
        addq.l  #1,a1               ; skip index
        bra.s   .a2slp
.a2sf:  move.b  (a1),d0
        andi.w  #$00FF,d0
        rts
.a2nf:  move.w  #-1,d0
        rts

sp_lut:
        dc.b    '*',27, '-',28, ',',29, '.',30, '#',31
        dc.b    '+',32, '?',33, '!',34, '<',35, '>',36
        dc.b    $FF
        even

;=======================================================================
; RENDER : copie scroll_buf vers scr_work avec déformation sinus
; Pour chaque ligne l (0..FONT_H-1) :
;   d_y = SCROLL_YBASE + sine[sine_ph + l*SINE_STEP] + sine[sine_ph*2 + l*SINE_STEP]/2
;   Copie SCROLL_WORDS words de scroll_buf[l] vers scr_work[d_y]
;   (avec OR pour ne pas écraser le fond)
;=======================================================================
render:
        movem.l d0-d7/a0-a4,-(sp)

        lea     sine_table,a3
        lea     scroll_buf,a4
        move.l  scr_work,a2         ; base de l'écran de travail

        move.w  sine_ph,d6          ; phase sinus de départ pour ce frame

        move.w  #FONT_H-1,d7

.rnlp:
        ; --- Calcule déplacement Y ---
        ; Sinus 1 (SINE_AMPL1)
        move.w  d6,d0
        andi.w  #SINE_BYTEMASK,d0
        move.w  (a3,d0.w),d1        ; s1 (signé, -SINE_AMPL1..+SINE_AMPL1)

        ; Sinus 2 (harmonique fréquence double, amplitude /2)
        move.w  d6,d0
        add.w   d0,d0               ; *2
        andi.w  #SINE_BYTEMASK,d0
        move.w  (a3,d0.w),d2
        asr.w   #1,d2               ; /2

        ; Y destination = YBASE + s1 + s2
        move.w  #SCROLL_YBASE,d0
        add.w   d1,d0
        add.w   d2,d0

        ; Clip [0, SCREEN_H-1]
        bmi.s   .rnskip
        cmpi.w  #SCREEN_H-1,d0
        bgt.s   .rnskip

        ; Adresse ligne dans scr_work (1 plan : 40 octets/ligne)
        mulu    #SCR_BYTES_LINE,d0
        lea     (a2,d0.l),a0        ; a0 = adresse ligne destination

        ; --- Copie 20 words (40 octets) de scroll_buf[l] vers écran ---
        ; OR avec MOVE.L déroulé : 10 REPT × (move.l = 4 octets) = 40 octets = 20 words
        REPT    10
        move.l  (a4)+,d0
        or.l    d0,(a0)+
        ENDR

        ; Saute le 21ème word (marge droite = 2 octets)
        addq.l  #2,a4
        bra.s   .rnnxt

.rnskip:
        ; Ligne clippée : avance quand même dans scroll_buf
        adda.w  #SBUF_BYTES,a4

.rnnxt:
        ; Avance phase sinus pour la prochaine ligne
        addi.w  #SINE_STEP*2,d6
        andi.w  #SINE_BYTEMASK,d6

        dbf     d7,.rnlp

        movem.l (sp)+,d0-d7/a0-a4
        rts

;=======================================================================
; DONNÉES INITIALISÉES
;=======================================================================
        SECTION DATA
        even

;--- Table rasters (RASTER_COUNT = 32 couleurs, format ST $0RGB) ---
; Dégradé arc-en-ciel : rouge → jaune → vert → cyan → bleu → violet → rouge
raster_tab:
        dc.w    $0700,$0710,$0720,$0730,$0740,$0750,$0760,$0770   ; rouge→jaune
        dc.w    $0570,$0370,$0170,$0070,$0071,$0073,$0075,$0077   ; jaune→cyan
        dc.w    $0057,$0037,$0017,$0007,$0107,$0307,$0507,$0707   ; cyan→violet
        dc.w    $0706,$0704,$0702,$0700,$0500,$0300,$0100,$0300   ; violet→rouge
raster_tab_end:

;--- Palette initiale ---
; Couleur 0 = fond noir, couleur 1 = encre (remplacée par rasters pendant l'affichage)
font_palette:
        dc.w    $0000               ; 0 fond
        dc.w    $0777               ; 1 texte (blanc avant rasters)
        dc.w    $0555               ; 2..15 non critiques
        dc.w    $0333,$0700,$0770,$0070,$0077,$0007,$0707
        dc.w    $0730,$0370,$0073,$0307,$0450,$0111

;--- Texte défilant ---
        even
scroll_text:
        dc.b    "   BIENVENUE SUR ATARI ST ! "
        dc.b    "SINUS SCROLLER EN ASSEMBLEUR 68000 AVEC FONTE BITMAP 16X16 "
        dc.b    "PRE-DECALAGE 16 PHASES + RASTERS ARC-EN-CIEL VIA TIMER B "
        dc.b    "DOUBLE BUFFERING - AMPLITUDE SINUS DOUBLE HARMONIQUE "
        dc.b    "LE 68000 A 8MHZ RESTE IMBATTABLE POUR LA DEMO SCENE ! "
        dc.b    "GREETINGS TO ALL ATARI ST LOVERS AND CODERS !!!   "
        dc.b    0
        even

;=======================================================================
; FONTE BITMAP EMBARQUÉE
; 47 glyphes, 16 lignes × 1 word (2 octets) chacun
; Ordre : A(0)..Z(25), espace(26), *(27) -(28) ,(29) .(30) #(31)
;         +(32) ?(33) !(34) <(35) >(36), 0(37)..9(46)
;=======================================================================
; NOTE INCBIN PI1 :
; Pour utiliser une fonte externe (fichier Degas PI1) :
; 1) Commenter le bloc font_data..font_data_end ci-dessous
; 2) Décommenter les 3 lignes suivantes :
;    font_pi1:    incbin "font16x16.pi1"
;    font_data    equ    font_pi1+34         ; skip header 34 octets
;    font_palette equ    font_pi1+2          ; palette dans header PI1
; 3) Dans gen_preshift, lire le plan 0 du format PI1 entrelacé :
;    offset_char = row*PI1_BYTES_PER_LINE + col*8  (4 plans * 2 octets)
;    plan0_word  = mot à l'offset_char + y*PI1_BYTES_PER_LINE
;=======================================================================

        even
font_data:

; ---- A ----
        dc.w    $0180,$03C0,$0660,$0C30,$1818,$1818,$1FF8,$3FFC
        dc.w    $300C,$600E,$6006,$C003,$C003,$C003,$0000,$0000
; ---- B ----
        dc.w    $FFC0,$FFF0,$C038,$C01C,$C018,$C030,$FFF0,$FFF8
        dc.w    $C01C,$C00C,$C00C,$C01C,$FFF8,$FFF0,$0000,$0000
; ---- C ----
        dc.w    $07F0,$1FFC,$3806,$700E,$E000,$C000,$C000,$C000
        dc.w    $E000,$700E,$3806,$1FFC,$07F0,$0000,$0000,$0000
; ---- D ----
        dc.w    $FF00,$FFC0,$C0E0,$C030,$C018,$C00C,$C00C,$C00C
        dc.w    $C018,$C030,$C0E0,$FFC0,$FF00,$0000,$0000,$0000
; ---- E ----
        dc.w    $FFFC,$FFFC,$C000,$C000,$C000,$FFF8,$FFF8,$C000
        dc.w    $C000,$C000,$C000,$FFFC,$FFFC,$0000,$0000,$0000
; ---- F ----
        dc.w    $FFFC,$FFFC,$C000,$C000,$C000,$FFF8,$FFF8,$C000
        dc.w    $C000,$C000,$C000,$C000,$C000,$0000,$0000,$0000
; ---- G ----
        dc.w    $07F0,$1FFC,$3806,$700E,$E000,$C000,$C0FF,$C0FF
        dc.w    $E00E,$7006,$3806,$1FFC,$07F0,$0000,$0000,$0000
; ---- H ----
        dc.w    $C003,$C003,$C003,$C003,$C003,$FFFF,$FFFF,$C003
        dc.w    $C003,$C003,$C003,$C003,$C003,$0000,$0000,$0000
; ---- I ----
        dc.w    $7FFE,$7FFE,$03C0,$03C0,$03C0,$03C0,$03C0,$03C0
        dc.w    $03C0,$03C0,$03C0,$7FFE,$7FFE,$0000,$0000,$0000
; ---- J ----
        dc.w    $1FFE,$1FFE,$01C0,$01C0,$01C0,$01C0,$01C0,$01C0
        dc.w    $C1C0,$C1C0,$E380,$7F00,$3E00,$0000,$0000,$0000
; ---- K ----
        dc.w    $C038,$C030,$C060,$C0C0,$C180,$C300,$CE00,$CF00
        dc.w    $C380,$C1C0,$C0E0,$C060,$C030,$C018,$0000,$0000
; ---- L ----
        dc.w    $C000,$C000,$C000,$C000,$C000,$C000,$C000,$C000
        dc.w    $C000,$C000,$C000,$FFFC,$FFFC,$0000,$0000,$0000
; ---- M ----
        dc.w    $C003,$E007,$F00F,$D80B,$CC19,$C631,$C361,$C1C1
        dc.w    $C001,$C001,$C001,$C001,$C001,$0000,$0000,$0000
; ---- N ----
        dc.w    $C003,$E003,$F003,$D803,$CC03,$C603,$C303,$C183
        dc.w    $C0C3,$C063,$C033,$C01B,$C00F,$C007,$0000,$0000
; ---- O ----
        dc.w    $07E0,$1FF8,$380C,$700E,$E003,$C001,$C001,$C001
        dc.w    $E003,$700E,$380C,$1FF8,$07E0,$0000,$0000,$0000
; ---- P ----
        dc.w    $FFE0,$FFF8,$C01C,$C00C,$C01C,$FFF8,$FFE0,$C000
        dc.w    $C000,$C000,$C000,$C000,$C000,$0000,$0000,$0000
; ---- Q ----
        dc.w    $07E0,$1FF8,$380C,$700E,$E003,$C001,$C001,$C001
        dc.w    $C031,$E019,$700F,$381F,$1FF8,$07FC,$0000,$0000
; ---- R ----
        dc.w    $FFE0,$FFF8,$C01C,$C00C,$C01C,$FFF8,$FFE0,$C1C0
        dc.w    $C0E0,$C060,$C030,$C018,$C00C,$0000,$0000,$0000
; ---- S ----
        dc.w    $1FF8,$3FFC,$600C,$C006,$C000,$7F00,$1FFC,$00FE
        dc.w    $0006,$C006,$E00C,$7FFC,$1FF8,$0000,$0000,$0000
; ---- T ----
        dc.w    $FFFF,$FFFF,$03C0,$03C0,$03C0,$03C0,$03C0,$03C0
        dc.w    $03C0,$03C0,$03C0,$03C0,$03C0,$0000,$0000,$0000
; ---- U ----
        dc.w    $C003,$C003,$C003,$C003,$C003,$C003,$C003,$C003
        dc.w    $C003,$C003,$6006,$3FFC,$0FF0,$0000,$0000,$0000
; ---- V ----
        dc.w    $C003,$C003,$6006,$6006,$3004,$300C,$180C,$1818
        dc.w    $0C30,$0C60,$0660,$03C0,$0180,$0000,$0000,$0000
; ---- W ----
        dc.w    $C003,$C003,$C003,$C003,$C003,$C003,$CC33,$CC33
        dc.w    $C633,$C633,$D66B,$FCFF,$78C3,$0000,$0000,$0000
; ---- X ----
        dc.w    $C003,$6006,$300C,$1818,$0C30,$07E0,$03C0,$03C0
        dc.w    $07E0,$0C30,$1818,$300C,$6006,$C003,$0000,$0000
; ---- Y ----
        dc.w    $C003,$6006,$3014,$1818,$0C30,$07E0,$03C0,$03C0
        dc.w    $03C0,$03C0,$03C0,$03C0,$03C0,$0000,$0000,$0000
; ---- Z ----
        dc.w    $FFFF,$FFFF,$0006,$000C,$0030,$0060,$01C0,$0380
        dc.w    $0600,$0C00,$3000,$6000,$FFFF,$FFFF,$0000,$0000
; ---- ESPACE (26) ----
        dc.w    $0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w    $0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
; ---- * (27) ----
        dc.w    $0180,$09A4,$05A0,$0FF0,$7FFE,$0FF0,$05A0,$09A4
        dc.w    $0180,$0000,$0000,$0000,$0000,$0000,$0000,$0000
; ---- - (28) ----
        dc.w    $0000,$0000,$0000,$0000,$0000,$07F0,$07F0,$0000
        dc.w    $0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
; ---- , (29) ----
        dc.w    $0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w    $0000,$01C0,$01C0,$00C0,$00C0,$0080,$0000,$0000
; ---- . (30) ----
        dc.w    $0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
        dc.w    $0000,$0000,$01C0,$01C0,$0000,$0000,$0000,$0000
; ---- # (31) ----
        dc.w    $0C60,$0C60,$7FFE,$7FFE,$0C60,$0C60,$0C60,$7FFE
        dc.w    $7FFE,$0C60,$0C60,$0000,$0000,$0000,$0000,$0000
; ---- + (32) ----
        dc.w    $0180,$0180,$0180,$0FF0,$0FF0,$0180,$0180,$0180
        dc.w    $0000,$0000,$0000,$0000,$0000,$0000,$0000,$0000
; ---- ? (33) ----
        dc.w    $07E0,$1FF8,$300C,$C006,$C006,$001C,$00F0,$0380
        dc.w    $0180,$0000,$0000,$01C0,$01C0,$0000,$0000,$0000
; ---- ! (34) ----
        dc.w    $0180,$0180,$0180,$0180,$0180,$0180,$0180,$0180
        dc.w    $0000,$0000,$01C0,$01C0,$0000,$0000,$0000,$0000
; ---- < (35) ----
        dc.w    $0018,$0060,$0180,$0600,$1800,$6000,$8000,$6000
        dc.w    $1800,$0600,$0180,$0060,$0018,$0000,$0000,$0000
; ---- > (36) ----
        dc.w    $C000,$3000,$0C00,$0300,$00C0,$0018,$0008,$0018
        dc.w    $00C0,$0300,$0C00,$3000,$C000,$0000,$0000,$0000
; ---- 0 (37) ----
        dc.w    $07E0,$1FF8,$300C,$6006,$C003,$C00B,$C013,$C023
        dc.w    $C043,$C083,$6006,$300C,$1FF8,$07E0,$0000,$0000
; ---- 1 (38) ----
        dc.w    $0300,$0F00,$3F00,$0300,$0300,$0300,$0300,$0300
        dc.w    $0300,$0300,$0300,$3FFC,$3FFC,$0000,$0000,$0000
; ---- 2 (39) ----
        dc.w    $07E0,$1FF8,$300C,$C006,$C006,$000C,$00F0,$0780
        dc.w    $1C00,$6000,$C000,$FFFF,$FFFF,$0000,$0000,$0000
; ---- 3 (40) ----
        dc.w    $07E0,$1FF8,$300C,$C006,$0006,$001C,$07F0,$07F0
        dc.w    $001C,$0006,$C006,$300C,$1FF8,$07E0,$0000,$0000
; ---- 4 (41) ----
        dc.w    $0030,$0070,$00F0,$01B0,$0330,$0630,$FFFE,$FFFE
        dc.w    $0030,$0030,$0030,$0030,$0030,$0000,$0000,$0000
; ---- 5 (42) ----
        dc.w    $FFFF,$FFFF,$C000,$C000,$C000,$FFF0,$FFFC,$001E
        dc.w    $0006,$C006,$E00C,$7FFC,$1FF0,$0000,$0000,$0000
; ---- 6 (43) ----
        dc.w    $03F8,$0FF8,$1C00,$3000,$6000,$DFF8,$FFF8,$F00C
        dc.w    $C006,$C006,$E00C,$7FFC,$1FF0,$0000,$0000,$0000
; ---- 7 (44) ----
        dc.w    $FFFF,$FFFF,$0003,$0006,$000C,$0018,$0030,$0060
        dc.w    $00C0,$0180,$0300,$0600,$0C00,$0000,$0000,$0000
; ---- 8 (45) ----
        dc.w    $07E0,$1FF8,$300C,$C003,$300C,$1FF8,$07E0,$07E0
        dc.w    $1FF8,$300C,$C003,$300C,$1FF8,$07E0,$0000,$0000
; ---- 9 (46) ----
        dc.w    $07E0,$1FF8,$300C,$C006,$C006,$C006,$3FFE,$0FFE
        dc.w    $0006,$000C,$0018,$6030,$7FE0,$1FC0,$0000,$0000

font_data_end:
        even

;=======================================================================
; SECTION BSS
;=======================================================================
        SECTION BSS
        even

old_ssp:        ds.l 1
old_scr_ptr:    ds.l 1
old_vbl:        ds.l 1
old_tb:         ds.l 1
old_sr:         ds.w 1

scr_work:       ds.l 1              ; adresse buffer de travail (dessin)
scr_show:       ds.l 1              ; adresse buffer affiché (Shifter)

scr_ptr:        ds.l 1              ; pointeur dans scroll_text
sx_sub:         ds.w 1              ; sous-pixel (0..15)
sine_ph:        ds.w 1              ; phase sinus globale (octet index)
frame_ctr:      ds.w 1

rst_ptr:        ds.l 1              ; pointeur courant dans raster_tab
rst_cnt:        ds.w 1              ; compteur lignes raster

        even
; Table sinus 512 words signés
sine_table:     ds.w SINE_ENTRIES

        even
; Buffer scroll 16 lignes × 21 words
scroll_buf:     ds.w FONT_H * SBUF_WORDS

        even
; Tables pré-décalées : 16 phases × 47 chars × 16 lignes × 4 octets = 47872 octets
preshifted_font: ds.l NUM_PRESHIFTS * FONT_CHARS * FONT_H

        even
; Réserve pour 2 écrans + alignement 256 octets
screen_mem:     ds.b (SCREEN_BYTES + 256) * 2

        END