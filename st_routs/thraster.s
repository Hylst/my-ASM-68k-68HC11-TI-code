; *************************************************************
; * DYNAMIC THICK RASTERS - ATARI ST                          *
; * Effet : Barres de couleur avec épaisseur variable         *
; * Assembleur : Devpac (68000)                        *
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

        ; --- Initialisation : Génération des tables de Sinus ---
        bsr     gen_tables

        ; --- Sauvegarde de l'état du système ---
        move.w  sr,old_sr
        move.l  $70.w,old_vbl
        move.l  $120.w,old_timerb
        move.b  $fffa07.w,old_iera
        move.b  $fffa09.w,old_ierb
        move.b  $fffa13.w,old_imra
        move.b  $fffa1b.w,old_tbcr
        move.b  $fffa21.w,old_tbdr
        
        movem.l $ff8240.w,d0-d7     ; Sauve la palette complète
        movem.l d0-d7,old_palette

        ; --- Préparation des Interruptions ---
        move.w  #$2700,sr           ; Coupe les interruptions pour le setup
        
        clr.b   $fffa07.w           ; Stop interruptions MFP
        clr.b   $fffa09.w
        
        move.l  #my_vbl,$70.w       ; Installe notre VBL
        move.l  #my_timerb,$120.w   ; Installe notre Timer B
        
        bset    #0,$fffa07.w        ; Autorise Timer B dans IERA
        bset    #0,$fffa13.w        ; Autorise Timer B dans IMRA
        
        move.w  #$2300,sr           ; Réactive les interruptions

; --- Boucle Principale ---
main_loop:
        stop    #$2300              ; Attend le signal VBL
        
        ; Animation des index
        addq.w  #2,pos_index        ; Vitesse mouvement vertical
        and.w   #1022,pos_index
        
        addq.w  #4,thick_index      ; Vitesse variation épaisseur
        and.w   #1022,thick_index

        ; Test de la touche Espace (code $39)
        cmpi.b  #$39,$fffc02.w
        bne.s   main_loop

exit:
        ; --- Restauration du système ---
        move.w  #$2700,sr
        move.b  old_iera,$fffa07.w
        move.b  old_ierb,$fffa09.w
        move.b  old_imra,$fffa13.w
        move.b  old_tbcr,$fffa1b.w
        move.b  old_tbdr,$fffa21.w
        move.l  old_vbl,$70.w
        move.l  old_timerb,$120.w
        
        movem.l old_palette,d0-d7
        movem.l d0-d7,$ff8240.w     ; Restaure les couleurs originales
        move.w  old_sr,sr

        move.l  old_stack,-(sp)
        move.w  #32,-(sp)
        trap    #1
        addq.l  #6,sp
        
        clr.w   -(sp)               ; Pterm()
        trap    #1

; *************************************************************
; * ROUTINES D'INTERRUPTION                                   *
; *************************************************************

my_vbl:
        clr.b   $fffa1b.w           ; Stop Timer B
        
        ; Récupère la position de départ (Sinus 1)
        move.w  pos_index,d0
        lea     pos_table,a0
        move.w  (a0,d0.w),d1
        
        ; Récupère l'épaisseur actuelle (Sinus 2)
        move.w  thick_index,d0
        lea     thick_table,a0
        move.w  (a0,d0.w),d2
        move.w  d2,current_thick    ; Stocke pour le Timer B
        
        move.b  d1,$fffa21.w        ; Ligne de départ
        move.b  #8,$fffa1b.w        ; Start Timer B (Event count mode)
        
        move.l  #raster_colors,raster_ptr
        move.w  #$000,$ff8240.w     ; Fond noir par défaut
        
        bclr    #0,$fffa0f.w        ; Fin d'interruption (ISRA)
        rte

my_timerb:
        ; --- Modification de la couleur ---
        move.l  raster_ptr,a0
        move.w  (a0)+,$ff8240.w     ; Applique la couleur et avance
        move.l  a0,raster_ptr
        
        ; --- Gestion de l'épaisseur ---
        ; On utilise la valeur dynamique pour la prochaine interruption
        move.w  current_thick,d0
        move.b  d0,$fffa21.w        ; Prochaine interruption dans N lignes
        
        ; Si on atteint la fin de la table de couleurs, on stoppe
        cmp.l   #raster_colors_end,a0
        bge.s   .stop_raster
        
        bclr    #0,$fffa0f.w        ; ISRA
        rte

.stop_raster:
        clr.b   $fffa1b.w           ; Plus rien à dessiner pour cette frame
        move.w  #$000,$ff8240.w     ; Reset fond en noir
        bclr    #0,$fffa0f.w
        rte

; *************************************************************
; * GENERATION DES TABLES (Sinus de Minsky)                   *
; *************************************************************

gen_tables:
        ; Table 1 : Position verticale (Amplitude ~70 lignes)
        lea     pos_table,a0
        move.w  #0,d0               ; Y
        move.w  #5000,d1            ; X
        move.w  #511,d7
.loop_p:
        move.w  d0,d2
        asr.w   #6,d2               ; Scale sinus
        add.w   #80,d2              ; Offset (milieu écran)
        move.w  d2,(a0)+
        
        ; Minsky circle
        move.w  d0,d2
        asr.w   #7,d2
        sub.w   d2,d1
        move.w  d1,d2
        asr.w   #7,d2
        add.w   d2,d0
        dbf     d7,.loop_p

        ; Table 2 : Epaisseur (Valeurs entre 1 et 8)
        lea     thick_table,a0
        move.w  #0,d0
        move.w  #3000,d1
        move.w  #511,d7
.loop_t:
        move.w  d0,d2
        asr.w   #9,d2               ; Réduit l'amplitude
        and.w   #7,d2               ; Garde entre 0 et 7
        addq.w  #1,d2               ; Épaisseur mini = 1
        move.w  d2,(a0)+
        
        move.w  d0,d2
        asr.w   #7,d2
        sub.w   d2,d1
        move.w  d1,d2
        asr.w   #7,d2
        add.w   d2,d0
        dbf     d7,.loop_t
        rts

; *************************************************************
; * DONNEES                                                   *
; *************************************************************

        SECTION DATA

; Dégradé de couleurs (ST Palette format)
raster_colors:
        dc.w $001,$002,$003,$004,$005,$006,$007
        dc.w $117,$227,$337,$447,$557,$667,$777
        dc.w $667,$557,$447,$337,$227,$117,$007
        dc.w $006,$005,$004,$003,$002,$001,$000
raster_colors_end:
        even

        SECTION BSS
; Sauvegardes système
old_stack:      ds.l 1
old_vbl:        ds.l 1
old_timerb:     ds.l 1
old_sr:         ds.w 1
old_palette:    ds.w 16
old_iera:       ds.b 1
old_ierb:       ds.b 1
old_imra:       ds.b 1
old_tbcr:       ds.b 1
old_tbdr:       ds.b 1

; Variables d'animation
pos_index:      ds.w 1
thick_index:    ds.w 1
current_thick:  ds.w 1
raster_ptr:     ds.l 1

; Tables pré-calculées
pos_table:      ds.w 512
thick_table:    ds.w 512

        END
		
; DOC sur cet effet d'épaisseur dynamique :

; Dans la routine my_vbl, on lit une valeur dans thick_table. Cette valeur (de 1 à 8) définit "combien de lignes" le Shifter va attendre avant de changer la couleur suivante.

; Dans my_timerb, on écrit cette valeur dans $fffa21.w. Si l'épaisseur est de 5, la barre de couleur sera 5 fois plus haute.

; Gestion propre du MFP :

; On sauvegarde tous les registres de contrôle (IERA, IMRA, TBCR). C'est crucial pour ne pas perdre le clavier ou le lecteur de disquette au retour sous le bureau.

; On utilise move.w #$2700, sr pour empêcher une interruption de survenir pendant qu'on change les vecteurs $70 et $120.

; Générateur de sinus intégré :

; Le code génère ses propres tables de mouvement au lancement. L'amplitude et la vitesse sont calculées pour que les barres restent bien visibles à l'écran.

; Optimisation 68000 :

; Utilisation de movem.l pour la palette.

; Utilisation du bit Even pour s'assurer que les données sont bien alignées en mémoire (indispensable sur 68000).