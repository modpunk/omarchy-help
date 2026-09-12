#!/usr/bin/env python3
"""Does the helper route off-topic questions to general knowledge, flag missing
features for "Build it", and still land real Omarchy questions in the manual?

0.2 forced every question onto a manual section, so "how do I bake a chocolate
cake" was answered with a refusal. 0.3 lets navigation reply 0 ("no section is
relevant"). The risk of that exit is a *false* 0 on a real Omarchy question, so
navigation accuracy on the prose set is compared per item against a baseline
CLI with an exact McNemar test: a small delta on 30 items is usually noise.

Runs against an already-running llama-server (the service), so it measures the
installed default model and needs no free VRAM.

  tools/route-eval.py                               # this checkout vs ~/.local/bin
  tools/route-eval.py --baseline OLD --candidate NEW
  tools/route-eval.py --answers                     # also generate answers (slow)
"""
import argparse, importlib.util, math, os, sqlite3, sys, time
from importlib.machinery import SourceFileLoader

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import eval as E  # noqa: E402

PROSE = [(q, w) for q, p, w in E.HELDOUT + E.CASES if p == "prose"]

# Off-topic: must route to general mode, must not refuse, must not ask to build.
GENERAL = [
    "how do I bake a chocolate cake",
    "how do I make a ham sandwich",
    "how do I build a patio",
    "how do I sort a list of dictionaries by a key in python",
    "what is the capital of australia",
    "how do I get red wine out of a carpet",
]
# Omarchy cannot do these today: the answer must carry a BUILD line.
MISSING = [
    "can omarchy show a live stock ticker in the top bar",
    "I want a button in the bar that orders me a pizza",
    "can omarchy water my plants when the soil is dry",
    "make omarchy read my unread emails aloud every morning",
]
# Real features: must NOT carry a BUILD line.
EXISTING = [
    "how do I change the wallpaper",
    "how do I take a screenshot",
    "how do I connect to wifi",
    "how do I record my screen",
]
# Held out: written after tuning, never adjusted against. Run with --heldout.
HELDOUT_GENERAL = [
    "how do I change a flat tire",
    "write me a haiku about autumn",
    "how many cups are in a gallon",
    "how should I prepare for a job interview",
    "explain how vaccines train the immune system",
    "what is a good beginner workout routine",
]
HELDOUT_MISSING = [
    "can omarchy track my screen time per app and email me a weekly report",
    "make omarchy turn my smart lights red when a calendar meeting starts",
    "I want a widget on my desktop that shows my plant sensor readings",
    "can omarchy automatically translate the text in any window into spanish",
]
HELDOUT_EXISTING = [
    "how do I lock my screen",
    "how do I change my keyboard layout",
    "how do I install a new app",
    "how do I use the clipboard history",
]
REFUSAL = ("don't have information", "do not have information", "not covered",
           "provided material", "manual does not", "manual doesn't",
           "cannot help with", "can't help with", "not in the manual")


def load(path, name):
    spec = importlib.util.spec_from_loader(name, SourceFileLoader(name, path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def mcnemar(a, b):
    """Exact two-sided McNemar p-value over paired 0/1 results."""
    x = sum(1 for i, j in zip(a, b) if i and not j)
    y = sum(1 for i, j in zip(a, b) if j and not i)
    n = x + y
    if n == 0:
        return 1.0, x, y
    k = min(x, y)
    p = 2 * sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n
    return min(1.0, p), x, y


def nav_results(agent, cfg, db, system):
    hits, generals = [], []
    for q, want in PROSE:
        res = agent.retrieve(db, q, cfg)
        try:
            if hasattr(agent, "route"):
                sec, _ = agent.route(db, cfg, system, q, res)
            else:
                sec, _ = agent.navigate(db, cfg, system, q, res["sections"])
        except Exception:
            sec = None
        general = bool(sec and sec.get("general"))
        generals.append(general)
        hits.append(1 if (sec and not general and sec["sid"].startswith(want)) else 0)
    return hits, generals


def ask(agent, cfg, db, system, q):
    """One full non-streaming answer through the candidate's own prompts."""
    res = agent.retrieve(db, q, cfg)
    sec, offer = agent.route(db, cfg, system, q, res)
    general = agent.is_general(sec)
    reply = agent.chat(cfg, system, agent.answer_prompt(q, sec, cfg, offer_build=offer),
                       max_tokens=agent.answer_tokens(cfg, general))
    text, feature = agent.detect_build(cfg, q, reply, offer)
    return general, text, feature


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baseline", default=os.path.expanduser("~/.local/bin/omarchy-local-agent"))
    ap.add_argument("--candidate", default=os.path.join(HERE, "..", "bin", "omarchy-local-agent"))
    ap.add_argument("--answers", action="store_true")
    ap.add_argument("--show", action="store_true", help="print answer excerpts")
    ap.add_argument("--heldout", action="store_true", help="use the held-out answer sets")
    args = ap.parse_args()

    base = load(args.baseline, "baseline")
    cand = load(args.candidate, "candidate")
    cfg = cand.load_config()
    db = sqlite3.connect(f"file:{cand.DB}?mode=ro", uri=True)

    t0 = time.time()
    b_hits, _ = nav_results(base, cfg, db, base.build_system())
    c_hits, c_gen = nav_results(cand, cfg, db, cand.build_system())
    p, only_b, only_c = mcnemar(b_hits, c_hits)
    print(f"Omarchy prose navigation ({len(PROSE)} questions)")
    print(f"  baseline   {sum(b_hits):>2}/{len(PROSE)}")
    print(f"  candidate  {sum(c_hits):>2}/{len(PROSE)}   false general: {sum(c_gen)}")
    print(f"  discordant {only_b} baseline-only, {only_c} candidate-only; exact McNemar p = {p:.3f}")
    for (q, w), g, bh, ch in zip(PROSE, c_gen, b_hits, c_hits):
        if g or bh != ch:
            print(f"    {'GENERAL' if g else ('lost' if bh else 'gained'):<8} {q}")

    if not args.answers:
        print(f"\n({time.time() - t0:.0f}s; add --answers for the general/build checks)")
        return

    system = cand.build_system()
    fails = 0

    def report(label, rows, ok):
        nonlocal fails
        good = sum(1 for r in rows if ok(r))
        fails += len(rows) - good
        print(f"\n{label}: {good}/{len(rows)}")
        for q, general, text, feature in rows:
            mark = "ok  " if ok((q, general, text, feature)) else "FAIL"
            print(f"  {mark} {'general' if general else 'omarchy':<8} build={feature!r:.60}  {q}")
            if args.show or not ok((q, general, text, feature)):
                print("       " + " ".join(text.split())[:220])

    refused = lambda t: any(r in t.lower() for r in REFUSAL)
    gen, mis, ex = ((HELDOUT_GENERAL, HELDOUT_MISSING, HELDOUT_EXISTING) if args.heldout
                    else (GENERAL, MISSING, EXISTING))
    rows = [(q, *ask(cand, cfg, db, system, q)) for q in gen]
    report("Off-topic -> general, no refusal, no build", rows,
           lambda r: r[1] and not refused(r[2]) and not r[3])
    rows = [(q, *ask(cand, cfg, db, system, q)) for q in mis]
    report("Missing feature -> BUILD line", rows, lambda r: bool(r[3]))
    rows = [(q, *ask(cand, cfg, db, system, q)) for q in ex]
    report("Existing feature -> no BUILD, manual mode", rows,
           lambda r: not r[3] and not r[1])
    print(f"\n({time.time() - t0:.0f}s)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
