#pragma once

#include <simpleini\SimpleIni.h>
#include "ASIOSettings.h"

class ASIOSettingsFile
{
public:
  ASIOSettingsFile(ASIOSettings::Settings &info);
  ~ASIOSettingsFile();

  bool Open();
  bool Save();

private:
    CSimpleIni mIni;
    ASIOSettings::Settings &mInfo;
};

