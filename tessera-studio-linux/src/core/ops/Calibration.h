#pragma once
#include <string>
#include <functional>
namespace tessera {
struct CalibrateOptions { std::string model_path; std::string out_path; std::string dataset; int threads=0; };
struct QuantizeOptions { std::string model_path; std::string out_path; std::string quant_type="q4_k_m"; };
using ProgressCb = std::function<void(const std::string& line, float pct)>;
int run_calibrate(const CalibrateOptions &opts, ProgressCb cb);
int run_quantize(const QuantizeOptions &opts, ProgressCb cb);
int run_evolve(const std::string &config, ProgressCb cb);
int run_evaluate(const std::string &model, ProgressCb cb);
} // namespace tessera
