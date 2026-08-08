#pragma once
#include <string>
namespace tessera {
// Port of TesseraReceipt / C2PAManifest
struct Receipt {
    std::string id;
    std::string action;
    std::string payload_json;
    std::string signature;
};
} // namespace tessera
