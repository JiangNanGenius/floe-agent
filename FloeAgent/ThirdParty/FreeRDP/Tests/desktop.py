# SPDX-License-Identifier: MPL-2.0
"""Synthetic desktop; records only generated fixture input, never real credentials."""
import os
from pathlib import Path
import tkinter as tk
root = tk.Tk()
root.geometry('800x600+0+0')
root.overrideredirect(True)
root.configure(bg='#123456')
label = tk.Label(root, text='Floe RDP loopback qualification', bg='#123456', fg='white', font=('Sans', 24))
label.pack(pady=40)
entry = tk.Entry(root, font=('Sans', 24))
entry.pack(pady=30)
entry.focus_force()
events = Path(os.environ['FLOE_RDP_FIXTURE_EVENTS'])
def record(event):
    with events.open('a') as stream:
        stream.write(event.keysym + '\n')
    label.configure(text='Remote input received: ' + event.keysym)
root.bind('<KeyPress>', record)
root.bind('<Button-1>', lambda _: entry.focus_force())
root.mainloop()
