#pragma once
#include <string>
namespace tessera {
class EncryptedVolume{public:bool create(const std::string&,const std::string&);bool open(const std::string&,const std::string&);bool close(const std::string&);};
#ifndef TESSERA_ENTERPRISE
class PleadTheFifth{public:void arm();void trigger();};
#endif
} // namespace tessera
