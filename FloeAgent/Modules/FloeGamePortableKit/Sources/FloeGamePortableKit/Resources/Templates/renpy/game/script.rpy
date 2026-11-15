default floe_clicks = 0
default floe_stage = "menu"
default floe_started = False

label start:
    $ floe_started = True
    $ floe_clicks = 0
    $ floe_stage = "opening"
    scene black
    "A paper lantern floats above still water."
    $ floe_clicks += 1
    $ floe_stage = "choice"
    menu:
        "Reach for the lantern":
            $ floe_clicks += 1
            $ floe_stage = "answered"
            "The light answers with a warm pulse."
        "Wait in the dark":
            $ floe_clicks += 10
            $ floe_stage = "waited"
            "The water keeps its secret."
    $ floe_stage = "done"
    "Signal complete. Clicks: [floe_clicks]"
    return
