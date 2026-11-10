"""Replay of the app's live logic (IoT-ui-enhancement-v2.0-harry, 2026-11-09) on both group members' recordings.

RESpeck: 32 samples per BLE packet (~2.56 s); the app sees a packet when its last sample is taken.
Per sample: HAR window (50) and social window (100) are advanced; every `step` samples a result is made.
We precompute model outputs for the window ending at every sample, then replay the app's display logic.
"""
import sys, itertools, json
import numpy as np, pandas as pd, tensorflow as tf
from collections import Counter, deque

FS = 12.5; PKT = 32
CACHE = str(__import__('pathlib').Path(__file__).resolve().parent / 'cache') + '/'
APP = '/Users/harryyang/IoT-ui-enhancement-v2.0-harry/assets/models/'
FIN = str(__import__('pathlib').Path(__file__).resolve().parent / 'models') + '/'
HAR = ["sittingStanding", "lyingBack", "lyingLeft", "lyingRight", "lyingStomach", "normalWalking",
       "shuffleWalking", "ascending", "descending", "running", "miscMovement"]
STATIC = set(range(5))

meta = pd.read_csv(CACHE + 'real_meta.csv')
z = np.load(CACHE + 'real.npz'); D, O = z['data'], z['offsets']
sig = [D[O[i]:O[i + 1]] for i in range(len(meta))]


def tfl(path):
    it = tf.lite.Interpreter(path); d = it.get_input_details()[0]; o = it.get_output_details()[0]
    def run(X, bs=256):
        out = []
        for s in range(0, len(X), bs):
            b = X[s:s + bs].astype(np.float32)
            it.resize_tensor_input(d['index'], [len(b)] + list(d['shape'][1:])); it.allocate_tensors()
            it.set_tensor(d['index'], b); it.invoke(); out.append(it.get_tensor(o['index']).copy())
        return np.concatenate(out)
    return run


def windows_ending(x, W, mode='full'):
    """Window ending at every sample t (t>=W-1). mode: full | tile<k> (last k samples tiled to W)."""
    idx = np.arange(W - 1, len(x))
    if mode == 'full':
        return idx, np.stack([x[t - W + 1:t + 1] for t in idx])
    k = int(mode[4:])
    out = []
    for t in idx:
        r = x[t - k + 1:t + 1]
        rep = np.concatenate([r] * (W // k + 1))[-W:]
        out.append(rep)
    return idx, np.stack(out)


def seg(i, part, n):
    s = sig[i]
    return s[-n:] if part == 'end' else s[:n]


def build_pairs(rng, kind, n_per_person=60):
    pairs = []
    for person in meta.person.unique():
        m = meta[meta.person == person]
        st = m[m.stationary]
        dy = m[~m.stationary]
        cand = []
        if kind == 'social':      # same posture, different social class
            for (_, a), (_, b) in itertools.permutations(st.iterrows(), 2):
                if a.posture == b.posture and a.social_y != b.social_y:
                    cand.append((a.name, b.name))
        elif kind == 'har':       # any change of HAR class
            for (_, a), (_, b) in itertools.permutations(m.iterrows(), 2):
                if a.har_y != b.har_y and (a.stationary is False or a.sub == 'normal') and (b.stationary is False or b.sub == 'normal'):
                    cand.append((a.name, b.name))
        elif kind == 'stop':      # moving -> stationary with a social signal
            for (_, a), (_, b) in itertools.product(dy.iterrows(), st.iterrows()):
                cand.append((a.name, b.name))
        sel = rng.choice(len(cand), min(n_per_person, len(cand)), replace=False)
        pairs += [cand[j] for j in sel]
    return pairs


NA, NB = 200, 300          # 16 s of A, 24 s of B


class Smoother:
    def __init__(s, n): s.q = deque(maxlen=n)
    def add(s, lab):
        s.q.append(lab); c = Counter(s.q); top = max(c.values())
        for l in reversed(s.q):           # tie -> most recent
            if c[l] == top: return l


def replay(Ph, Ps, step, har_feed='packet', smooth=3, gate=True, phase=0, social_hold=None):
    """Returns per-sample-time display arrays (display updates at packet arrivals).
    Ph[t], Ps[t]: argmax of window ending at sample t (or -1 if not full)."""
    n = len(Ph)
    sm = Smoother(smooth) if smooth else None
    har_shown = -1; soc_shown = -1
    since_h = since_s = 0
    disp_h = np.full(n, -1); disp_s = np.full(n, -1)
    pend_h = []
    pk_end = [t for t in range(n) if (t - phase) % PKT == PKT - 1]
    cur_h, cur_s = -1, -1
    last_soc = -1
    for t in range(n):
        since_h += 1; since_s += 1
        if Ph[t] >= 0 and since_h >= step:
            since_h = 0; pend_h.append(Ph[t])
            if har_feed == 'all':
                har_shown = sm.add(Ph[t]) if sm else Ph[t]
        # social gate uses the HAR shown at this sample (mid-packet updates only when har_feed=='all')
        moving = har_shown >= 0 and har_shown not in STATIC
        if Ps[t] >= 0 and since_s >= step:
            if gate and moving:
                pass                                  # paused: keep since_s growing -> runs as soon as gate opens
            else:
                since_s = 0; last_soc = Ps[t]
        if gate and moving:
            last_soc = -2                             # shown as 'paused'
        if (t - phase) % PKT == PKT - 1:              # packet delivered -> UI refresh
            if har_feed == 'packet' and pend_h:
                har_shown = sm.add(pend_h[-1]) if sm else pend_h[-1]
            pend_h = []
            cur_h = har_shown
            moving = cur_h >= 0 and cur_h not in STATIC
            cur_s = -2 if (gate and moving) else last_soc
        disp_h[t] = cur_h; disp_s[t] = cur_s
    return disp_h, disp_s


def latency(disp, target, t0, hold=int(4 * FS)):
    """Seconds from change (sample t0) until display == target and stays for `hold` samples (or to the end)."""
    n = len(disp)
    for t in range(t0, n):
        if disp[t] == target:
            e = min(n, t + hold)
            if np.all(disp[t:e] == target):
                return (t - t0 + 1) / FS
    return np.nan


def main():
    rng = np.random.default_rng(0)
    which = sys.argv[1] if len(sys.argv) > 1 else 'app'
    root = APP if which == 'app' else FIN
    har_m = tfl(root + 'harry_har_cnn.tflite'); soc_m = tfl(root + 'harry_social_rnn.tflite')
    kinds = {'social': build_pairs(rng, 'social'), 'har': build_pairs(rng, 'har'), 'stop': build_pairs(rng, 'stop', 40)}
    soc_modes = ['full', 'tile50', 'tile64']
    har_modes = ['full', 'tile25', 'tile38']
    rows = []
    cache = {}
    for kind, pairs in kinds.items():
        for a, b in pairs:
            x = np.concatenate([seg(a, 'end', NA), seg(b, 'start', NB)])
            preds = {}
            for mode in har_modes:
                idx, X = windows_ending(x, 50, mode); P = np.full(len(x), -1); P[idx] = har_m(X).argmax(1); preds['h_' + mode] = P
            for mode in soc_modes:
                idx, X = windows_ending(x, 100, mode); P = np.full(len(x), -1); P[idx] = soc_m(X).argmax(1); preds['s_' + mode] = P
            tb_h = int(meta.har_y[b]); tb_s = int(meta.social_y[b])
            for step in (25, 12, 6):
                for hf, smooth in (('packet', 3), ('all', 3), ('all', 0), ('all', 5)):
                    if step == 25 and hf == 'all' and smooth == 5: continue
                    for hm, sm_ in (('full','full'),('tile25','full'),('tile38','full'),('full','tile50'),('full','tile64')):
                            for gate in ((False,) if kind == 'har' else (False, True)):
                                ph_list = range(0, PKT, 8)
                                lh, ls = [], []
                                for ph in ph_list:
                                    dh, ds = replay(preds['h_' + hm], preds['s_' + sm_], step, hf, smooth, gate, ph)
                                    lh.append(latency(dh, tb_h, NA)); ls.append(latency(ds, tb_s, NA) if tb_s >= 0 else np.nan)
                                    # steady-state accuracy over the last 12 s of B
                                acc_h = np.mean(dh[-150:] == tb_h); acc_s = np.mean(ds[-150:] == tb_s) if tb_s >= 0 else np.nan
                                rows.append(dict(kind=kind, person=meta.person[b], a=meta.file[a][6:40], b=meta.file[b][6:40],
                                                 step=step, har_feed=hf, smooth=smooth, har_mode=hm, soc_mode=sm_, gate=gate,
                                                 lat_h=np.nanmean(lh) if not np.all(np.isnan(lh)) else np.nan,
                                                 lat_s=np.nanmean(ls) if not np.all(np.isnan(ls)) else np.nan,
                                                 miss_h=np.mean(np.isnan(lh)), miss_s=np.mean(np.isnan(ls)) if tb_s >= 0 else np.nan,
                                                 acc_h=acc_h, acc_s=acc_s))
    df = pd.DataFrame(rows)
    df.to_csv(str(__import__('pathlib').Path(__file__).resolve().parent / 'results' / f'app_latency_{which}.csv'), index=False)
    print('done', len(df))


if __name__ == '__main__':
    main()
