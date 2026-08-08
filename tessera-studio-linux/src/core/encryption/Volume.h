#pragma once
#include <string>
namespace tessera {
class EncryptedVolume{public:bool create(const std::string&,const std::string&);bool open(const std::string&,const std::string&);bool close(const std::string&);};
class PleadTheFifth{public:void arm();void trigger();};
} // namespace tessera
