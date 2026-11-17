import argparse
import re
from pathlib import Path

WIDTH = 11.4
ROW = 0.4
BAR = 0.22
SLOW = 2.0


def load(path):
    pods = {}
    old = set()
    for line in Path(path).read_text().splitlines():
        cols = line.split()
        if len(cols) < 5:
            continue
        t, name, phase, node, deleted = float(cols[0]), cols[1], cols[2], cols[3], cols[4]
        why = cols[5] if len(cols) > 5 else "<none>"
        if name not in pods and (phase in ("Succeeded", "Failed") or deleted != "<none>"):
            old.add(name)
        if name in old:
            continue
        p = pods.setdefault(name, {"name": name, "created": t, "queued": t, "node": "", "placed": None, "end": None,
                                   "result": ""})
        if node != "<none>" and p["placed"] is None:
            p["placed"] = t
            p["node"] = node
        if why != "<none>":
            p["result"] = "вытеснен"
        if p["end"] is None and (phase in ("Succeeded", "Failed") or deleted != "<none>"):
            p["end"] = t
            if not p["result"]:
                p["result"] = {"Succeeded": "готов", "Failed": "ошибка"}.get(phase, "удалён")
    return list(pods.values())


def split_name(name):
    m = re.match(r"^(.*)-(\d+)-[a-z0-9]{5}$", name)
    if m:
        return m.group(1), int(m.group(2))
    m = re.match(r"^(.*)-[a-z0-9]{5}$", name)
    return (m.group(1) if m else name), -1


def ordered(pods):
    jobs = []
    for p in sorted(pods, key=lambda p: p["queued"]):
        job = split_name(p["name"])[0]
        if job not in jobs:
            jobs.append(job)
    return sorted(pods, key=lambda p: (jobs.index(split_name(p["name"])[0]), split_name(p["name"])[1], p["created"]))


def table(pods, t0, last, since):
    print(f"{'под':<26} {'узел':<11} {'создан':>7} {'на узле':>8} {'конец':>7} {'ждал, с':>8}  итог")
    for p in pods:
        placed = p["placed"]
        end = p["end"] if p["end"] is not None else last
        wait = (placed if placed is not None else end) - p["created"]
        print(f"{p['name']:<26} {p['node'] or '-':<11} {p['created'] - t0:>7.1f} "
              f"{(f'{placed - t0:.1f}' if placed is not None else '-'):>8} {end - t0:>7.1f} {wait:>8.1f}  {p['result'] or 'работает'}")
    for job, t in since.items():
        print(f"задание {job} создано на {t - t0:.1f} с")


def tex(pods, t0, last, urgent, quota):
    span = max(last - t0, 1.0)
    step = 10 if span <= 120 else 20 if span <= 240 else 60
    sx = WIDTH / span
    rows = len(pods)
    out = ["\\begin{tikzpicture}[x=1cm,y=1cm,font=\\scriptsize]"]
    top = 0.15
    bottom = -rows * ROW
    tick = 0
    while tick <= span + 0.01:
        x = tick * sx
        out.append(f"\\draw[black!12] ({x:.3f},{top}) -- ({x:.3f},{bottom:.3f});")
        out.append(f"\\node[anchor=north,text=black!65] at ({x:.3f},{bottom:.3f}) {{{tick}}};")
        tick += step
    out.append(f"\\node[anchor=north,text=black!65] at ({WIDTH / 2:.3f},{bottom - 0.32:.3f}) {{время от запуска задачи, с}};")
    seen = {}
    for i, p in enumerate(pods):
        y = -(i + 0.5) * ROW
        lo, hi = y - BAR / 2, y + BAR / 2
        job, index = split_name(p["name"])
        seen[(job, index)] = seen.get((job, index), 0) + 1
        label = job if index < 0 else f"часть {index}"
        if seen[(job, index)] > 1:
            label += " (повтор)"
        end = p["end"] if p["end"] is not None else last
        placed = p["placed"] if p["placed"] is not None else end
        q, a, b, c = ((v - t0) * sx for v in (p["queued"], p["created"], placed, end))
        out.append(f"\\node[anchor=east] at (-0.12,{y:.3f}) {{{label}}};")
        if a - q > 0.03:
            out.append(f"\\draw[hhwait!80!black,pattern=north east lines,pattern color=hhwait!80!black,rounded corners=1pt] "
                       f"({q:.3f},{lo:.3f}) rectangle ({a - 0.02:.3f},{hi:.3f});")
        if b - a > 0.03:
            out.append(f"\\fill[hhwait,rounded corners=1pt] ({a:.3f},{lo:.3f}) rectangle ({b - 0.02:.3f},{hi:.3f});")
        color = "hhurgent" if job in urgent else "hhrun"
        if c - b > 0.03:
            out.append(f"\\fill[{color},rounded corners=1pt] ({b:.3f},{lo:.3f}) rectangle ({c:.3f},{hi:.3f});")
        note = p["node"].replace("hh-", "")
        if p["result"] == "вытеснен":
            out.append(f"\\draw[black,line width=0.9pt] ({c - 0.07:.3f},{y - 0.07:.3f}) -- ({c + 0.07:.3f},{y + 0.07:.3f}) "
                       f"({c - 0.07:.3f},{y + 0.07:.3f}) -- ({c + 0.07:.3f},{y - 0.07:.3f});")
            note += ", вытеснен"
        elif p["result"] == "ошибка":
            note += ", ошибка"
        out.append(f"\\node[anchor=west,text=black!65] at ({c + 0.12:.3f},{y:.3f}) {{{note}}};")
    ly = top + 0.38
    legend = []
    if quota:
        legend.append(("quota", "пода нет: квота"))
    legend += [("hhwait", "Pending: ждёт узел"), ("hhrun", "работает на узле")]
    if urgent:
        legend.append(("hhurgent", "срочная задача"))
    x = 0.0
    for color, text in legend:
        box = f"({x:.3f},{ly - BAR / 2:.3f}) rectangle ({x + 0.45:.3f},{ly + BAR / 2:.3f})"
        if color == "quota":
            out.append(f"\\draw[hhwait!80!black,pattern=north east lines,pattern color=hhwait!80!black,rounded corners=1pt] {box};")
        else:
            out.append(f"\\fill[{color},rounded corners=1pt] {box};")
        out.append(f"\\node[anchor=west] at ({x + 0.5:.3f},{ly:.3f}) {{{text}}};")
        x += 0.5 + 0.155 * len(text) + 0.5
    out.append("\\end{tikzpicture}")
    return "\n".join(out) + "\n"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("log")
    p.add_argument("name")
    p.add_argument("--urgent", action="append", default=[])
    p.add_argument("--since", action="append", default=[])
    a = p.parse_args()
    since = {job: float(t) for job, t in (s.split("=", 1) for s in a.since)}
    pods = load(a.log)
    if not pods:
        raise SystemExit(f"в {a.log} нет подов")
    for pod in pods:
        job = split_name(pod["name"])[0]
        if job in since:
            pod["queued"] = min(pod["created"], since[job])
    pods = ordered(pods)
    t0 = min(pod["queued"] for pod in pods)
    last = max(max(pod["end"] or 0, pod["placed"] or 0, pod["created"]) for pod in pods)
    table(pods, t0, last, since)
    waits = [(pod["placed"] if pod["placed"] is not None else last) - pod["created"] for pod in pods]
    queues = [pod["created"] - pod["queued"] for pod in pods]
    slow = [w for w in waits if w > SLOW]
    evicted = sum(1 for pod in pods if pod["result"] == "вытеснен")
    line = (f"подов: {len(pods)}, ждали узел дольше {SLOW:g} с: {len(slow)}, самое долгое ожидание {max(waits):.1f} с, "
            f"вытеснено: {evicted}, всё заняло {last - t0:.1f} с")
    if since:
        line += f", дольше всего под не создавался {max(queues):.1f} с"
    print(line)
    out = Path(__file__).resolve().parent.parent / "report" / "out"
    (out / f"gantt-{a.name}.tex").write_text(tex(pods, t0, last, set(a.urgent), bool(since)), encoding="utf-8")
    values = {"Pods": len(pods), "Waited": len(slow), "MaxWait": f"{max(waits):.0f}",
              "Evicted": evicted, "Total": f"{last - t0:.0f}", "MaxQueue": f"{max(queues):.0f}"}
    for job, t in since.items():
        mine = [pod for pod in pods if split_name(pod["name"])[0] == job]
        if mine:
            values[job.split("-")[-1].capitalize() + "Queue"] = f"{min(pod['created'] for pod in mine) - t:.0f}"
    (out / f"vars-{a.name}.tex").write_text(
        "".join(f"\\renewcommand{{\\{a.name}{k}}}{{{v}}}\n" for k, v in values.items()), encoding="utf-8")


if __name__ == "__main__":
    main()
