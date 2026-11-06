// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Qualification examples, not a whitelist of accepted content.
public enum InteractiveExample: String, CaseIterable, Sendable {
    case chart, budget, parameter, process, preview
}

public enum InteractiveExamples {
    public static func document(_ example: InteractiveExample, owner: ContentOwner,
                                chinese: Bool = true) throws -> InteractiveDocument {
        func t(_ zh: String, _ en: String) -> String { chinese ? zh : en }
        let html: String
        let title: String
        let initial: JSONValue
        let model: JSONValue
        switch example {
        case .budget:
            title = t("人数与预算试算", "Budget calculator")
            initial = .object(["people": .number(20), "price": .number(80), "fixed": .number(500)])
            model = .object(["people": .number(20), "total": .number(2_100)])
            html = """
            <label for="people">\(t("人数", "People")) <output id="count"></output></label>
            <input id="people" type="range" min="1" max="100" value="20">
            <div class="row"><label>\(t("每人费用", "Cost per person")) <input id="price" type="number" min="0" max="10000" value="80"></label>
            <label>\(t("固定费用", "Fixed cost")) <input id="fixed" type="number" min="0" max="100000" value="500"></label></div>
            <div class="value">\(t("合计", "Total")) <output id="total"></output></div>
            <script>(function(){
            const people=document.getElementById('people'),price=document.getElementById('price'),fixed=document.getElementById('fixed');
            function update(save){const n=Number(people.value),p=Number(price.value),f=Number(fixed.value);if(![n,p,f].every(Number.isFinite)||p<0||f<0)return;
            document.getElementById('count').textContent=n;document.getElementById('total').textContent=(n*p+f).toFixed(2);
            if(save)floeInteractive.setState({privateContent:{people:n,price:p,fixed:f},modelContent:{people:n,total:n*p+f}}).catch(function(){});}
            floeInteractive.ready(function(s){const p=s.privateContent||{};people.value=p.people??20;price.value=p.price??80;fixed.value=p.fixed??500;update(false);
            [people,price,fixed].forEach(function(e){e.addEventListener('input',function(){update(true)})})});
            })();</script>
            """
        case .parameter:
            title = t("调整参数观察曲线", "Explore a changing parameter")
            initial = .object(["coefficient": .number(1)])
            model = .object(["coefficient": .number(1), "formula": .string("y=a*x*x")])
            html = """
            <label for="coefficient">a = <output id="a"></output></label><input id="coefficient" type="range" min="-3" max="3" step="0.1" value="1">
            <div>y = a × x²</div>
            <svg viewBox="0 0 500 300" role="img" aria-label="y = a x squared">
            <path d="M40 150H480M260 20V280" stroke="currentColor" opacity=".3"/>
            <text x="450" y="174" fill="currentColor">x</text><text x="270" y="30" fill="currentColor">y</text>
            <text x="43" y="174" fill="currentColor">−5</text><text x="450" y="174" fill="currentColor">5</text>
            <path id="curve" fill="none" stroke="var(--accent)" stroke-width="3"/></svg>
            <script>(function(){const input=document.getElementById('coefficient');
            function draw(save){const a=Number(input.value);document.getElementById('a').textContent=a.toFixed(1);let d='';
            for(let i=0;i<=100;i++){const x=-5+i/10,y=a*x*x;d+=(i?'L':'M')+(260+x*43)+','+(150-y*1.7)}
            document.getElementById('curve').setAttribute('d',d);
            if(save)floeInteractive.setState({privateContent:{coefficient:a},modelContent:{coefficient:a,formula:'y=a*x*x'}}).catch(function(){})}
            floeInteractive.ready(function(s){input.value=(s.privateContent||{}).coefficient??1;draw(false);input.addEventListener('input',function(){draw(true)})});
            })();</script>
            """
        case .process:
            title = t("逐步查看排序过程", "Step through a sort")
            initial = .object(["step": .number(0)])
            model = .object(["step": .number(0), "values": .array([5, 2, 4, 1, 3].map { .number(Double($0)) }), "complete": .bool(false)])
            html = """
            <div id="bars" class="row" style="align-items:end;min-height:150px"></div>
            <p><output id="step"></output></p><div class="row">
            <button id="back">\(t("上一步", "Previous"))</button><button id="next">\(t("下一步", "Next"))</button>
            <button id="play">\(t("播放", "Play"))</button></div>
            <script>(function(){const states=[[5,2,4,1,3]],a=states[0].slice();for(let end=a.length-1;end>0;end--){for(let i=0;i<end;i++){if(a[i]>a[i+1]){const v=a[i];a[i]=a[i+1];a[i+1]=v;states.push(a.slice())}}}
            let step=0,timer=null;const play=document.getElementById('play');
            function stop(){if(timer!==null)clearInterval(timer);timer=null;play.textContent='\(t("播放", "Play"))'}
            function draw(save){const bars=document.getElementById('bars');bars.replaceChildren();states[step].forEach(function(v){const b=document.createElement('div');b.style.cssText='background:var(--accent);color:var(--background);min-width:40px;text-align:center;padding:6px;height:'+(v*25)+'px';b.textContent=v;bars.appendChild(b)});
            document.getElementById('step').textContent=(step+1)+' / '+states.length;
            document.getElementById('back').disabled=step===0;document.getElementById('next').disabled=step===states.length-1;
            if(save)floeInteractive.setState({privateContent:{step:step},modelContent:{step:step,values:states[step],complete:step===states.length-1}}).catch(function(){})}
            floeInteractive.ready(function(s){step=Math.max(0,Math.min(states.length-1,Math.trunc((s.privateContent||{}).step||0)));draw(false);
            document.getElementById('back').onclick=function(){stop();step=Math.max(0,step-1);draw(true)};
            document.getElementById('next').onclick=function(){stop();step=Math.min(states.length-1,step+1);draw(true)};
            play.onclick=function(){if(timer!==null){stop();return}if(step===states.length-1)step=0;play.textContent='\(t("暂停", "Pause"))';timer=setInterval(function(){step=Math.min(states.length-1,step+1);draw(true);if(step===states.length-1)stop()},500)}});
            floeInteractive.onActive(function(active){if(!active)stop()});
            })();</script>
            """
        case .preview:
            title = t("可点击界面预览", "Clickable interface preview")
            initial = .object(["tab": .string("overview"), "note": .string("")])
            model = initial
            html = """
            <div class="row"><button id="overview">\(t("概览", "Overview"))</button><button id="details">\(t("明细", "Details"))</button></div>
            <section id="panel" style="padding:16px 0"></section>
            <label for="note">\(t("备注", "Note"))</label><input id="note" maxlength="1000" type="text">
            <script>(function(){let tab='overview';const note=document.getElementById('note');
            function show(save){document.getElementById('panel').textContent=tab==='overview'?'\(t("概览页面：展示方案的主要内容。", "Overview: the main points of the proposal."))':'\(t("明细页面：查看组成部分和补充信息。", "Details: inspect the parts and supporting information."))';
            ['overview','details'].forEach(function(id){document.getElementById(id).setAttribute('aria-pressed',String(id===tab))});
            if(save)floeInteractive.setState({privateContent:{tab:tab,note:note.value},modelContent:{tab:tab,note:note.value}}).catch(function(){})}
            floeInteractive.ready(function(s){const p=s.privateContent||{};tab=p.tab==='details'?'details':'overview';note.value=p.note||'';show(false);
            ['overview','details'].forEach(function(id){document.getElementById(id).onclick=function(){tab=id;show(true)}});note.oninput=function(){show(true)}});
            })();</script>
            """
        case .chart:
            title = t("查看与比较数据", "Explore and compare data")
            initial = .object(["showB": .bool(true), "selectedX": .null])
            model = .object(["visibleSeries": .array([.string("A"), .string("B")]), "selectedX": .null])
            html = """
            <label><input type="checkbox" id="showB" checked> \(t("显示系列 B", "Show series B"))</label>
            <svg id="chart" viewBox="0 0 500 280" role="img" aria-label="Series A and B"><path d="M40 20V240H480" fill="none" stroke="currentColor" opacity=".4"/>
            <text x="45" y="265" fill="currentColor">0</text><text x="450" y="265" fill="currentColor">10</text>
            <text x="475" y="265" fill="currentColor">x</text><text x="15" y="30" fill="currentColor">y</text>
            <path id="lineA" fill="none" stroke="var(--accent)" stroke-width="3"/><path id="lineB" fill="none" stroke="currentColor" stroke-width="2" stroke-dasharray="6 4"/>
            <path id="guide" fill="none" stroke="currentColor" opacity=".5"/></svg><output id="selected"></output>
            <script>(function(){const xs=[0,1,3,6,10],a=[2,4,3,7,9],b=[4,3,6,5,8],show=document.getElementById('showB');let selected=null;
            function path(values){return values.map(function(v,i){return(i?'L':'M')+(40+xs[i]*43)+','+(240-v*21)}).join('')}
            function draw(save){document.getElementById('lineA').setAttribute('d',path(a));document.getElementById('lineB').setAttribute('d',show.checked?path(b):'');
            const i=selected===null?-1:xs.indexOf(selected);document.getElementById('guide').setAttribute('d',i<0?'':'M'+(40+selected*43)+' 20V240');
            document.getElementById('selected').textContent=i<0?'\(t("点按图表查看数值", "Tap the chart to inspect values"))':'x='+selected+' · A='+a[i]+(show.checked?' · B='+b[i]:'');
            if(save)floeInteractive.setState({privateContent:{showB:show.checked,selectedX:selected},modelContent:{visibleSeries:show.checked?['A','B']:['A'],selectedX:selected}}).catch(function(){})}
            floeInteractive.ready(function(s){const p=s.privateContent||{};show.checked=p.showB!==false;selected=xs.includes(p.selectedX)?p.selectedX:null;draw(false);
            show.onchange=function(){draw(true)};document.getElementById('chart').onpointerdown=function(event){const box=this.getBoundingClientRect(),x=((event.clientX-box.left)/box.width*500-40)/43;selected=xs.reduce(function(best,v){return Math.abs(v-x)<Math.abs(best-x)?v:best},xs[0]);draw(true)}});
            })();</script>
            """
        }
        return try InteractiveDocument(owner: owner, kind: example.rawValue, title: title, html: html,
            fallbackText: t("暂时无法显示交互内容，请重试或查看文字说明。", "This content could not be displayed. Retry or use the text explanation."),
            initialModelContent: model, initialPrivateContent: initial)
    }
}
