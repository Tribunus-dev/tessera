#pragma once

//
// tessera-convergence.h
//
// Velocity-based convergence gate shared by the GA (tessera-awq) and
// the L5 joint search (tessera-l5-joint). PR #11 (spec §10).
//
// The gate replaces scalar stagnation counters ("N generations without
// improvement > epsilon") with finite differences of the tracked
// series: a run converges when the last `window` transitions all move
// less than velocity_threshold per step AND the last window-1
// transitions all accelerate less than acceleration_threshold.
//
// Why velocity + acceleration: a fixed improvement epsilon cannot tell
// "moving slowly toward the optimum" from "jittering on a plateau".
// |velocity| < vth says the series is flat; |acceleration| < ath says
// the flatness is not a transient kink mid-descent. The 2x rule
// (ath = 2*vth) keeps the acceleration condition never tighter than
// the velocity condition alone: |a| <= |v_t| + |v_{t-1}| < 2*vth.
//
// Stateless and header-only: the caller owns the series via add()
// (once per generation / transition) and queries converged().
//   window <= 0 : disabled (never converges).
//   window == 1 : converges after ONE flat transition (2 scores),
//                 preserving the TESSERA_STAGNATION_LIMIT=1 e2e
//                 semantics.
//

#include <cmath>
#include <vector>

// Velocity-based convergence gate over a rolling score history.
// scores keeps at most window+1 entries: exactly enough transitions.
struct ts_velocity_gate {
    int   window = 0;                    // flat transitions required; 0 = off
    float velocity_threshold     = 0.0f; // max |first diff| per transition
    float acceleration_threshold = 0.0f; // max |second diff| per transition

    std::vector<float> scores;

    // Record one score (one generation / one transition). The history
    // is trimmed to window+1 so converged() only inspects the recent
    // window of transitions.
    void add(float score) {
        scores.push_back(score);
        if (window > 0 && (int)scores.size() > window + 1) {
            scores.erase(scores.begin());
        }
    }

    // Newest first difference; 0 when fewer than 2 scores.
    float velocity() const {
        if (scores.size() < 2) return 0.0f;
        return scores.back() - scores[scores.size() - 2];
    }

    // Newest second difference; 0 when fewer than 3 scores.
    float acceleration() const {
        if (scores.size() < 3) return 0.0f;
        return (scores.back() - scores[scores.size() - 2])
             - (scores[scores.size() - 2] - scores[scores.size() - 3]);
    }

    // Number of recorded scores (transitions + 1).
    int size() const {
        return (int)scores.size();
    }

    // Drop all history; the gate starts cold again.
    void reset() {
        scores.clear();
    }

    // True when the last `window` transitions are flat in velocity
    // AND the last window-1 transitions are flat in acceleration.
    bool converged() const {
        if (window <= 0) return false;
        const int n = (int)scores.size();
        if (n < window + 1) return false;
        // Transitions live between consecutive scores: transition i
        // is scores[i] -> scores[i+1]. The last `window` transitions
        // are i in [n-1-window, n-2].
        for (int i = n - 1 - window; i <= n - 2; i++) {
            if (std::fabs(scores[i + 1] - scores[i]) >= velocity_threshold) return false;
        }
        // Second difference at transition i (i >= 1) is v_i - v_{i-1}
        // (v_i = scores[i+1] - scores[i]). The last window-1 are i in
        // [n-window, n-2]. n >= window+1 guarantees i >= 1.
        for (int i = n - window; i <= n - 2; i++) {
            const float v_cur  = scores[i + 1] - scores[i];
            const float v_prev = scores[i] - scores[i - 1];
            if (std::fabs(v_cur - v_prev) >= acceleration_threshold) return false;
        }
        return true;
    }
};
