-- Copyright (c) 2017-present, Facebook, Inc.
-- All rights reserved.

-- This source code is licensed under the BSD-style license found in the
-- LICENSE file in the root directory of this source tree. An additional grant
-- of patent rights can be found in the PATENTS file in the same directory.

local argcheck = require 'argcheck'
local tnt = require 'torchnet'
require 'torchnet.sequential'
local threads = require 'threads'
require 'wav2letter' -- for numberedfilesdataset
local data = {}
local dict39 = {
   ao = "aa",
   ax = "ah",
   ["ax-h"] = "ah",
   axr = "er",
   hv = "hh",
   ix = "ih",
   el = "l",
   em = "m",
   en = "n",
   nx = "n",
   eng = "ng",
   zh = "sh",
   ux = "uw",
   pcl = "h#",
   tcl = "h#",
   kcl = "h#",
   bcl = "h#",
   dcl = "h#",
   gcl = "h#",
   pau = "h#",
   ["#h"] = "h#",
   epi = "h#",
   q = "h#"
}

local function batchmerge(sample)
   local newsample = {}
   for k,v in pairs(sample) do
      newsample[k] = v
   end
   -- we override input with a concatenated tensor
   local imax = 0
   local channels
   for _,input in ipairs(sample.input) do
      imax = math.max(imax, input:size(1))
      channels = channels or input:size(2)
   end
   local mergeinput = sample.input[1].new(#sample.input, imax, channels):fill(0)
   for i,input in ipairs(sample.input) do
      mergeinput[i]:narrow(1, 1, input:size(1)):copy(input)
   end
   newsample.input = mergeinput
   return newsample
end

data.tensor2string = argcheck{
   noordered = true,
   {name='tensor', type='torch.LongTensor'},
   {name='dict', type='table'},
   call =
      function(tensor, dict)
         local str = {}
         assert(tensor:nDimension() <= 1)
         tensor:apply(
            function(idx)
               table.insert(str, assert(dict[idx]))
            end
         )
         return table.concat(str)
      end
}

data.words2tensor = argcheck{
   noordered = true,
   {name='words', type='string'},
   {name='dict', type='tds.Hash'},
   {name='unk', type='number', opt=true},
   {name='unkdict', type='tds.Hash', opt=true},
   call =
      function(words, dict, unk, unkdict)
         assert(not (unk and unkdict), 'unk and unkdict must not be specified simultaneously')
         local tokens = {}
         for token in words:gmatch('(%S+)') do
            local tokenidx = dict[token]
            if not tokenidx then
               if unk then
                  tokenidx = unk
               elseif unkdict then
                  tokenidx = #dict+#unkdict
                  unkdict[token] = tokenidx
               else
                  error(string.format('unknown token <%s>', token))
               end
            end
            table.insert(tokens, tokenidx)
         end
         return torch.LongTensor(tokens)
      end
}

data.dictcollapsephones = argcheck{
   noordered = true,
   {name='dictionary', type='table'},
   call =
      function(dict)
         local cdict = {}
         for _, phone in ipairs(dict) do
            if not dict39[phone] then
               data.dictadd{dictionary=cdict, token=phone}
            end
         end
         for _, phone in ipairs(dict) do
            if dict39[phone] then
               data.dictadd{dictionary=cdict, token=phone, idx=assert(cdict[dict39[phone]])}
            end
         end
         return cdict
      end
}

data.dictadd = argcheck{
   noordered = true,
   {name='dictionary', type='table'},
   {name='token', type='string'},
   {name='idx', type='number', opt=true},
   call =
      function(dict, token, idx)
         local idx = idx or #dict+1
         assert(not dict[token], 'duplicate entry name in dictionary')
         dict[token] = idx
         if not dict[idx] then
            dict[idx] = token
         end
      end
}

data.newdict = argcheck{
   {name='path', type='string'},
   call =
      function(path)
         local dict = {}
         for line in io.lines(path) do
            local token, idx = line:match('^(%S+)%s*(%d+)$')
            idx = tonumber(idx)
            if token and idx then
               data.dictadd{dictionary=dict, token=token, idx=idx}
            else
               data.dictadd{dictionary=dict, token=line}
            end
         end
         return dict
      end
}

data.dictmaxvalue =
   function(dict)
      local maxvalue = 0
      for k, v in pairs(dict) do
         maxvalue = math.max(maxvalue, v)
      end
      return maxvalue
   end

data.newsampler =
   function(samplersize)
      local resampleperm = torch.LongTensor()
      local function resample()
         resampleperm:resize(0)
      end
      local sampler =
         threads.safe(
            function(dataset, idx)
               if resampleperm:nDimension() == 0 then
                  print(
                     string.format(
                        '| resampling: size=%d%s',
                        dataset:size(),
                        (samplersize and samplersize > 0)
                           and string.format(" (narrowing to %d)", samplersize)
                           or ""
                     ))
                  resampleperm:randperm(dataset:size())
                  if samplersize and samplersize > 0 then
                     assert(samplersize <= dataset:size(), "expected resampling size <= dataset size")
                     -- make sure we do not change resampleperm pointer
                     -- as it is shared across threads
                     resampleperm:set(resampleperm:storage(), 1, samplersize)
                  end
               end
               return resampleperm[idx]
            end
         )
      return sampler, resample
   end

data.namelist = argcheck{
   {name='names', type='string'},
   call =
      function(names)
         local list = {}
         for name in names:gmatch('([^%+]+)') do
            table.insert(list, name)
         end
         return list
      end
}

data.label2string = argcheck{
   {name='labels', type='torch.LongTensor'},
   {name='dict', type='table'},
   {name='spacing', type='string', default=''},
   call =
      function(tensor, dict, spc)
         local str = {}
         assert(tensor:nDimension() == 1, '1d tensor expected')
         for i=1,tensor:size(1) do
            local lbl = dict[tensor[i]]
            if not lbl then
               error(string.format("unknown label <%s>", tensor[i]))
            end
            table.insert(str, lbl)
         end
         return table.concat(str, spc)
      end
}

data.transform = argcheck{
   {name='dataset', type='tnt.Dataset'},
   {name='transforms', type='table', opt=true},
   call =
      function(dataset, transforms)
         if transforms then
            return tnt.TransformDataset{
               dataset = dataset,
               transforms = transforms
            }
         else
            return dataset
         end
      end
}

data.partition = argcheck{
   {name='dataset', type='tnt.Dataset'},
   {name='n', type='number'},
   {name='id', type='number'},
   call =
      function(dataset, n, id)
         assert(id >= 1 and id <= n, "invalid id range")
         if n == 1 then
            return dataset
         else
            local partitions = {}
            for i=1,n do
               partitions[tostring(i)] = math.floor(dataset:size()/n)
            end
            return tnt.SplitDataset{
               dataset = dataset,
               partitions = partitions,
               initialpartition = "" .. id
            }
         end
      end
}

data.resample = argcheck{
   {name='dataset', type='tnt.Dataset'},
   {name='sampler', type='function', opt=true},
   {name='size', type='number', opt=true},
   call =
      function(dataset, sampler, size)
         if sampler or (size and size > 0) then
            return tnt.ResampleDataset{
               dataset = dataset,
               sampler = sampler,
               size = size
            }
         else
            return dataset
         end
      end
}

data.filtersizesampler = argcheck{
   {name='sizedataset', type='tnt.Dataset'},
   {name='filter', type='function'},
   call =
      function(sizedataset, filter)
         local perm = torch.zeros(sizedataset:size())
         local size = 0
         for i=1,sizedataset:size() do
            local sz = sizedataset:get(i)
            assert(sz.isz and sz.tsz, 'sizedataset:get() should return {isz=, tsz=}')
            if filter(sz.isz, sz.tsz) then
               size = size + 1
               perm[size] = i
            end
         end
         print(string.format("| %d/%d filtered samples", size, sizedataset:size()))
         return
            function(_, idx)
               return perm[idx]
            end, size
      end
}

data.mapconcat = argcheck{
   {name='closure', type='function'},
   {name='args', type='table'},
   {name='maxload', type='number', opt=true},
   call =
      function(closure, args, maxload)
         local datasets = {}
         for i, arg in ipairs(args) do
            datasets[i] = closure(arg)
         end
         local dataset = tnt.ConcatDataset{datasets = datasets}
         -- brutal cut (one could allow pre-shuffling)
         if maxload and maxload > 0 then
            dataset = tnt.ResampleDataset{
               dataset = dataset,
               size = maxload
            }
         end
         return dataset
      end
}

data.batch = argcheck{
   {name='dataset', type='tnt.Dataset'},
   {name='sizedataset', type='tnt.Dataset'},
   {name='batchsize', type='number'},
   {name='batchresolution', type='number'},
   call =
      function(dataset, sizedataset, batchsize, batchresolution)
         assert(dataset:size() == sizedataset:size(), 'dataset and sizedataset do not have the same size')
         if batchsize <= 0 then
            return dataset
         else
            return tnt.BatchDataset{
               dataset = tnt.BucketSortedDataset{
                  dataset = dataset,
                  resolution = batchresolution,
                  samplesize =
                     function(dataset, idx)
                        local isz = sizedataset:get(idx).isz
                        assert(type(isz) == 'number', 'isz size feature nil or not a number')
                        return isz
                     end
               },
               batchsize = batchsize,
               merge = batchmerge,
            }
         end
      end
}

data.newfilterbysize = argcheck{
   noordered = true,
   {name='kw', type='number'},
   {name='dw', type='number'},
   {name='minisz', type='number', default=0},
   {name='maxisz', type='number', default=math.huge},
   {name='mintsz', type='number', default=0},
   {name='maxtsz', type='number', default=math.huge},
   {name='batchsize', type='number', default=0},
   {name='shift', type='number', default=0},
   call =
      function(kw, dw, minisz, maxisz, mintsz, maxtsz, batchsize, shift)
         return function(isz, tsz)
            if isz < math.max(kw+tsz*dw, minisz) or isz > maxisz then
               return false
            end
            if tsz < mintsz or tsz > maxtsz then
               return false
            end
            return true
         end
      end
}

data.newdataset = argcheck{
   noordered = true,
   {name="names", type="table"},
   {name="opt", type="table"},
   {name="dict", type="table"},
   {name="kw", type="number"},
   {name="dw", type="number"},
   {name="sampler", type="function", opt=true},
   {name="samplersize", type="number", opt=true},
   {name="mpirank", type="number", default=1},
   {name="mpisize", type="number", default=1},
   {name="maxload", type="number", opt=true},
   {name="aug", type="boolean", opt=true},
   {name="words", type="string", opt=true},
   call =
      function(names, opt, dict, kw, dw, sampler, samplersize, mpirank, mpisize, maxload, aug, words)
         local tnt = require 'torchnet'
         local data = require 'wav2letter.runtime.data'
         local readers = require 'wav2letter.readers'
         local transforms = require 'wav2letter.runtime.transforms'
         require 'wav2letter'
         local inputtransform, inputsizetransform = transforms.inputfromoptions(opt, kw, dw)
         local targettransform, targetsizetransform = transforms.target{
            surround = opt.surround ~= '' and assert(dict[opt.surround], 'invalid surround label') or nil,
            replabel = opt.replabel > 0 and {n=opt.replabel, dict=dict} or nil,
            uniq = true,
         }

         local function datasetwithfeatures(features, transforms)
            return data.transform{
               dataset = data.partition{
                  dataset = data.mapconcat{
                     closure = function(name)
                        local path = paths.concat(opt.datadir, name)
                        -- make sure path exist (also useful with automounts)
                        assert(
                           paths.dir(path),
                           string.format("directory <%s> does not exist", path)
                        )
                        return tnt.NumberedFilesDataset{
                           path = path,
                           features = features,
                        }
                     end,
                     args = names,
                     maxload = maxload
                  },
                  n = mpisize,
                  id = mpirank
               },
               transforms = transforms
            }
         end

         local features =
            {
               {
                  name = opt.input,
                  alias = "input",
                  reader = readers.audio{
                     samplerate = opt.samplerate,
                     channels = opt.channels
                  },
               },
               {
                  name = opt.target,
                  alias = "target",
                  reader = readers.tokens{
                     dictionary = dict
                  }
               },
            }
         if words then
            table.insert(
               features,
               {
                  name = words,
                  alias = "words",
                  reader = readers.words{}
               }
            )
         end
         local dataset = datasetwithfeatures(
            features,
            {
               input = inputtransform,
               target = targettransform
            }
         )

         local sizedataset = datasetwithfeatures(
            {
               {name = opt.input .. "sz", alias = "isz", reader = readers.number{}},
               {name = opt.target .. "sz", alias = "tsz", reader = readers.number{}}
            },
            {
               isz = inputsizetransform,
               tsz = targetsizetransform,
            }
         )

         -- filter
         local filter = data.newfilterbysize{
            kw = kw,
            dw = dw,
            minisz = opt.minisz,
            maxisz = opt.maxisz,
            maxtsz = opt.maxtsz,
            batchsize = opt.batchsize,
            shift = opt.shift
         }
         local filtersampler, filtersize = data.filtersizesampler{
            sizedataset = sizedataset,
            filter = filter
         }

         dataset = data.resample{
            dataset = dataset,
            sampler = filtersampler,
            size = filtersize
         }
         sizedataset = data.resample{
            dataset = sizedataset,
            sampler = filtersampler,
            size = filtersize
         }
         print('| batchresolution:', inputsizetransform(opt.samplerate/4))
         dataset = data.batch{
            dataset = data.resample{
               dataset = dataset,
               sampler = sampler,
               size = samplersize
            },
            sizedataset = data.resample{
               dataset = sizedataset,
               sampler = sampler,
               size = samplersize
            },
            batchsize = opt.batchsize,
            batchresolution = inputsizetransform(opt.samplerate/4), -- 250ms
         }

         return dataset
      end
}

data.newiterator = argcheck{
   noordered = true,
   {name="closure", type="function"},
   {name="nthread", type="number"},
   call =
      function(closure, nthread)
         if nthread == 0 then
            return tnt.DatasetIterator{
               dataset = closure(),
            }
         else
            return tnt.ParallelDatasetIterator{
               closure = closure,
               nthread = nthread
            }
         end
      end
}

return data
