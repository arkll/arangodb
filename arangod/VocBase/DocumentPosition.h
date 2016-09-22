////////////////////////////////////////////////////////////////////////////////
/// DISCLAIMER
///
/// Copyright 2014-2016 ArangoDB GmbH, Cologne, Germany
/// Copyright 2004-2014 triAGENS GmbH, Cologne, Germany
///
/// Licensed under the Apache License, Version 2.0 (the "License");
/// you may not use this file except in compliance with the License.
/// You may obtain a copy of the License at
///
///     http://www.apache.org/licenses/LICENSE-2.0
///
/// Unless required by applicable law or agreed to in writing, software
/// distributed under the License is distributed on an "AS IS" BASIS,
/// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
/// See the License for the specific language governing permissions and
/// limitations under the License.
///
/// Copyright holder is ArangoDB GmbH, Cologne, Germany
///
/// @author Jan Steemann
////////////////////////////////////////////////////////////////////////////////

#ifndef ARANGOD_VOC_BASE_DOCUMENT_POSITION_H
#define ARANGOD_VOC_BASE_DOCUMENT_POSITION_H 1

#include "Basics/Common.h"
#include "VocBase/DatafileHelper.h"
#include "VocBase/voc-types.h"

namespace arangodb {

class DocumentPosition {
 public:
  constexpr DocumentPosition() 
          : _fid(0), _dataptr(nullptr) {}

  DocumentPosition(void const* dataptr, TRI_voc_fid_t fid, bool isWal) noexcept
          : _fid(fid), _dataptr(dataptr) {
    if (isWal) {
      _fid |= arangodb::DatafileHelper::WalFileBitmask();
    }
  }

  DocumentPosition(DocumentPosition const& other) noexcept
          : _fid(other._fid), _dataptr(other._dataptr) {}
  
  DocumentPosition& operator=(DocumentPosition const& other) noexcept {
    _fid = other._fid;
    _dataptr = other._dataptr; 
    return *this;
  }
  
  DocumentPosition(DocumentPosition&& other) noexcept
          : _fid(other._fid), _dataptr(other._dataptr) {}
  
  DocumentPosition& operator=(DocumentPosition&& other) noexcept {
    _fid = other._fid;
    _dataptr = other._dataptr; 
    return *this;
  }

  ~DocumentPosition() {}
  
  inline void clear() noexcept {
    _fid = 0;
    _dataptr = nullptr;
  }

  inline bool valid() const noexcept {
    return _dataptr != nullptr;
  }
  
  // return the datafile id.
  inline TRI_voc_fid_t fid() const noexcept { 
    // unmask the WAL bit
    return (_fid & ~arangodb::DatafileHelper::WalFileBitmask());
  }

  // sets datafile id. note that the highest bit of the file id must
  // not be set. the high bit will be used internally to distinguish
  // between WAL files and datafiles. if the highest bit is set, the
  // master pointer points into the WAL, and if not, it points into
  // a datafile
  inline void fid(TRI_voc_fid_t fid, bool isWal) {
    // set the WAL bit if required
    _fid = fid;
    if (isWal) {
      _fid |= arangodb::DatafileHelper::WalFileBitmask();
    }
  }
  
  // return a pointer to the beginning of the Vpack  
  inline void const* dataptr() const noexcept { 
    return _dataptr;
  }
  
  // set the pointer to the beginning of the VPack memory
  inline void dataptr(void const* value) { _dataptr = value; }
  
  // whether or not the master pointer points into the WAL
  // the master pointer points into the WAL if the highest bit of
  // the _fid value is set, and to a datafile otherwise
  inline bool pointsToWal() const noexcept {
    // check whether the WAL bit is set
    return ((_fid & arangodb::DatafileHelper::WalFileBitmask()) == 1);
  }

 private:
  // this is the datafile identifier
  TRI_voc_fid_t _fid;   
  // this is the pointer to the beginning of the vpack
  void const* _dataptr; 

  static_assert(sizeof(TRI_voc_fid_t) == sizeof(uint64_t), "invalid fid size");
};
  
}

#endif
