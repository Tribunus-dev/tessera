#include "Calibration.h"
#include "../cli_resolver.h"
#include <cstdlib>
namespace tessera {
static int run_cli(const std::string &args, ProgressCb cb) {
    auto bin = resolve_cli_binary("");
    if (bin.empty()) { if(cb) cb("tessera-cli not found",0); return 127; }
    std::string cmd = bin.string() + " " + args + " 2>&1";
    if(cb) cb("exec: "+cmd, 0);
    int rc = std::system(cmd.c_str());
    if(cb) cb("done rc="+std::to_string(rc), 100);
    return rc;
}
int run_calibrate(const CalibrateOptions &o, ProgressCb cb){ return run_cli("calibrate --model "+o.model_path+" --out "+o.out_path, cb); }
int run_quantize(const QuantizeOptions &o, ProgressCb cb){ return run_cli("quantize --model "+o.model_path+" --out "+o.out_path+" --type "+o.quant_type, cb); }
int run_evolve(const std::string &c, ProgressCb cb){ return run_cli("evolve --config "+c, cb); }
int run_evaluate(const std::string &m, ProgressCb cb){ return run_cli("evaluate --model "+m, cb); }
} // namespace tessera
