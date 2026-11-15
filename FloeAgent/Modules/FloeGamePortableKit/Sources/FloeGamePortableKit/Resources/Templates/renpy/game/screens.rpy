screen say(who, what):
    window:
        id "window"
        background Solid("#102235")
        xfill True
        yalign 1.0
        padding (40, 28)
        vbox:
            spacing 10
            if who is not None:
                text who id "who" size 24 color "#8fd8df"
            text what id "what" size 30 color "#edf7ff"

# Original starter controls. F5/F9 are this project's explicit bindings,
# not a claim that every imported Ren'Py game uses them.
init python:
    if "floe_quick_menu" not in config.overlay_screens:
        config.overlay_screens.append("floe_quick_menu")

screen floe_quick_menu():
    zorder 100
    if not main_menu:
        key "K_F5" action QuickSave()
        key "K_F9" action QuickLoad(confirm=False)
        hbox:
            xalign 0.5
            yalign 0.03
            spacing 16
            textbutton "Save (F5)" action QuickSave() keyboard_focus False
            textbutton "Load (F9)" action QuickLoad(confirm=False) keyboard_focus False
            textbutton "Menu" action MainMenu(confirm=False) keyboard_focus False

screen choice(items):
    style_prefix "floe_choice"
    vbox:
        xalign 0.5
        yalign 0.62
        spacing 14
        for i in items:
            textbutton i.caption action i.action default_focus (i == items[0])

screen main_menu():
    tag menu
    add Solid("#08131f")
    vbox:
        xalign 0.5
        yalign 0.5
        spacing 22
        text "Floe Lantern" size 64 color "#edf7ff" xalign 0.5
        text "An original Ren'Py Web starter" size 24 color "#8fd8df" xalign 0.5
        textbutton "Begin" action Start()
        textbutton "Continue" action QuickLoad(confirm=False)
        key "K_F9" action QuickLoad(confirm=False)
        textbutton "Quit" action Quit(confirm=False)

style floe_choice_button:
    background Solid("#24566b")
    padding (26, 14)
style floe_choice_button_text:
    color "#edf7ff"
    size 28

style button:
    background Solid("#24566b")
    padding (26, 14)
style button_text:
    color "#edf7ff"
    size 28
