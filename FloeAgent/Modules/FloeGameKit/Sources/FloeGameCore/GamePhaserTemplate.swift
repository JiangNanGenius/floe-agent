// SPDX-License-Identifier: MPL-2.0
// The newly authored embedded starter-game files are additionally licensed MIT;
// the native builder remains MPL-2.0. Generated projects carry the full notice.
import Foundation
import Darwin

/// Uses a prepared resource directory, not a downloader or a native engine SDK.
public enum GamePhaserTemplate {
    public static let version = "3.90.0"
    public static let sourceCommit = "a9965625f49cf366584f454556b039e06e8adad6"
    public static let engineSHA256 = "2e1bc84f885ab5c62b11ebb72492bb334159ac5678b664c7cb2942fc979e44e3"
    public static let licenseSHA256 = "c3123cd25de4eccf1fd5a5a0a6fc872299116d1dbbb48b00f2554a4c35220a65"
    public static let noticesSHA256 = "fd57bb945a3993569b6eae1833d25e9eb1e2a988cca541ba8dc770b0b7b7792b"

    public static func create(at target: URL, resources: URL, title: String) throws {
        guard GameProjectContext.validIdentifier(title), target.isFileURL,
              !FileManager.default.fileExists(atPath: target.path) else { throw GameProjectError.destinationExists }
        let reader = try GameProjectReader(rootURL: resources, maximumFileBytes: 16 * 1_024 * 1_024)
        guard let engine = try reader.read(GameRelativePath("phaser.js")), GameDigest.sha256(engine) == engineSHA256,
              let license = try reader.read(GameRelativePath("LICENSE.phaser.md")), GameDigest.sha256(license) == licenseSHA256,
              let notices = try reader.read(GameRelativePath("THIRD-PARTY-NOTICES.txt")), GameDigest.sha256(notices) == noticesSHA256 else {
            throw GameProjectError.invalidArtifact
        }
        let parent = target.deletingLastPathComponent()
        try GameFileStorage.directory(parent)
        let stage = parent.appendingPathComponent(".game-template-" + UUID().uuidString)
        try GameFileStorage.directory(stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        let config = try JSONSerialization.data(withJSONObject: ["title": title, "speed": 180, "unknownExample": ["preserved": true]], options: [.sortedKeys])
        let files: [String: Data] = [
            "vendor/phaser.js": engine, "licenses/PHASER-MIT.txt": license,
            "licenses/THIRD-PARTY-NOTICES.txt": notices,
            "licenses/FLOE-STARTER-MIT.txt": Data(starterLicense.utf8),
            "package.json": Data(#"{"private":true,"dependencies":{"phaser":"3.90.0"}}"#.utf8),
            "game-config.json": config, "index.html": Data(html.utf8), "game.js": Data(script.utf8),
            "floe-inputs.json": Data(#"{"schemaVersion":1,"engine":"phaser","movement":{"left":["left"],"right":["right"],"up":["up"],"down":["down"]},"buttons":[]}"#.utf8)
        ]
        for (path, data) in files {
            let output = stage.appendingPathComponent(path)
            try GameFileStorage.directory(output.deletingLastPathComponent())
            try GameFileStorage.atomicWrite(data, to: output)
        }
        guard FileManager.default.fileExists(atPath: target.path) == false,
              renameatx_np(AT_FDCWD, stage.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else { throw GameProjectError.destinationExists }
    }

    private static let html = """
    <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Floe game</title><style>html,body{margin:0;background:#142b26;color:#fff;font:16px system-ui}canvas{display:block;margin:auto}p{text-align:center}</style>
    <script src="vendor/phaser.js"></script></head><body><div id="game"></div><p>方向键或点击地面移动 · Arrow keys or tap to move</p><script src="game.js"></script></body></html>
    """

    private static let script = """
    // SPDX-License-Identifier: MIT
    // Copyright (c) 2026 Floe contributors. See licenses/FLOE-STARTER-MIT.txt.
    (async function(){'use strict';
    const config=await (await fetch('game-config.json')).json();
    const state={x:80,y:200,score:0,frames:0};const input={left:false,right:false,up:false,down:false};let player,label,goal=null;
    function publish(kind,payload){if(window.floeGameHost)window.floeGameHost[kind](payload)}
    const scene={create:function(){
      this.add.rectangle(400,240,800,480,0x244d3c);for(let y=32;y<480;y+=64)for(let x=32;x<800;x+=64)this.add.rectangle(x,y,58,58,(x+y)%128?0x2c5944:0x315f48);
      this.add.rectangle(600,150,200,130,0x976c43);this.add.triangle(600,48,0,80,100,0,200,80,0xc25640).setOrigin(.5,0);
      this.add.text(600,150,config.title,{fontSize:'18px',color:'#fff4d0'}).setOrigin(.5);
      player=this.add.circle(state.x,state.y,14,0x8ed6ff).setStrokeStyle(3,0xf2fbff);
      this.coins=[160,300,440].map(x=>this.add.circle(x,200,9,0xffcf55));label=this.add.text(22,20,'',{fontSize:'22px',color:'#fff'});
      this.keys=this.input.keyboard.createCursorKeys();this.input.on('pointerdown',p=>{goal={x:p.x,y:p.y}});
      window.FloeGame=Object.freeze({
        input:(direction,pressed)=>{if(Object.hasOwn(input,direction)){input[direction]=!!pressed;goal=null;return true}return false},
        snapshot:()=>({...state,engineVersion:Phaser.VERSION}),
        restore:s=>{if(!s||!Number.isFinite(s.x)||!Number.isFinite(s.y)||!Number.isFinite(s.score))throw Error('Invalid save');state.x=Phaser.Math.Clamp(s.x,16,784);state.y=Phaser.Math.Clamp(s.y,16,464);state.score=Phaser.Math.Clamp(Math.floor(s.score),0,3);this.coins.forEach((c,i)=>c.setVisible(i>=state.score));player.setPosition(state.x,state.y);return true}
      });
      window.FloeTemplate=Object.freeze({config,state,game:this.game,scene:this,
        setPosition:(x,y)=>{state.x=Phaser.Math.Clamp(Number(x),16,784);state.y=Phaser.Math.Clamp(Number(y),16,464);player.setPosition(state.x,state.y)},
        setScore:n=>{state.score=Phaser.Math.Clamp(Math.floor(Number(n)),0,3);this.coins.forEach((c,i)=>c.setVisible(i>=state.score))}
      });
      publish('ready',{engine:'phaser',version:Phaser.VERSION,input:true,state:true});
    },update:function(time,delta){
      state.frames++;let dx=(input.right||this.keys.right.isDown?1:0)-(input.left||this.keys.left.isDown?1:0),dy=(input.down||this.keys.down.isDown?1:0)-(input.up||this.keys.up.isDown?1:0);
      if(goal){dx=Math.sign(goal.x-state.x);dy=Math.sign(goal.y-state.y);if(Math.abs(goal.x-state.x)<4)dx=0;if(Math.abs(goal.y-state.y)<4)dy=0}
      const length=Math.hypot(dx,dy)||1;const speed=Number.isFinite(config.speed)?Phaser.Math.Clamp(config.speed,20,600):180;
      state.x=Phaser.Math.Clamp(state.x+dx/length*speed*Math.min(delta,50)/1000,16,784);state.y=Phaser.Math.Clamp(state.y+dy/length*speed*Math.min(delta,50)/1000,16,464);player.setPosition(state.x,state.y);
      this.coins.forEach(c=>{if(c.visible&&Phaser.Math.Distance.Between(state.x,state.y,c.x,c.y)<24){c.setVisible(false);state.score++;publish('log','Collected '+state.score)}});label.setText('✉ '+state.score+' / 3');
    }};
    new Phaser.Game({type:Phaser.CANVAS,parent:'game',width:800,height:480,backgroundColor:'#244d3c',audio:{noAudio:true},banner:false,scale:{mode:Phaser.Scale.FIT,autoCenter:Phaser.Scale.CENTER_HORIZONTALLY},scene:scene});
    })().catch(e=>{if(window.floeGameHost)window.floeGameHost.log(String(e));throw e});
    """

    private static let starterLicense = """
    MIT License

    Copyright (c) 2026 Floe contributors

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """
}
