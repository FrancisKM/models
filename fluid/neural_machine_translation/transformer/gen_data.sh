#! /usr/bin/env bash

set -e

OUTPUT_DIR=$PWD/gen_data

###############################################################################
# change these variables for other WMT data
###############################################################################
OUTPUT_DIR_DATA="${OUTPUT_DIR}/wmt16_ende_data"
OUTPUT_DIR_BPE_DATA="${OUTPUT_DIR}/wmt16_ende_data_bpe"
LANG1="en"
LANG2="de"
# each of TRAIN_DATA: ata_url data_tgz data_file 
TRAIN_DATA=(
'http://www.statmt.org/europarl/v7/de-en.tgz' 'europarl-v7-de-en.tgz' 'europarl-v7.de-en'
'http://www.statmt.org/wmt13/training-parallel-commoncrawl.tgz' 'common-crawl.tgz' 'commoncrawl.de-en'
'http://data.statmt.org/wmt16/translation-task/training-parallel-nc-v11.tgz' 'nc-v11.tgz' 'training-parallel-nc-v11/news-commentary-v11.de-en'
)
# each of DEV_TEST_DATA: data_url data_tgz data_file_lang1 data_file_lang2
DEV_TEST_DATA=(
'http://data.statmt.org/wmt16/translation-task/dev.tgz' 'dev.tgz'
'.*/newstest201[45]-deen-ref.en.sgm' '.*/newstest201[45]-deen-src.de.sgm'
'http://data.statmt.org/wmt16/translation-task/test.tgz' 'test.tgz'
'.*/newstest2016-deen-ref.en.sgm' '.*/newstest2016-deen-src.de.sgm'
)
###############################################################################

mkdir -p $OUTPUT_DIR_DATA $OUTPUT_DIR_BPE_DATA

# Extract training data
for ((i=0;i<${#TRAIN_DATA[@]};i+=3)); do
  data=`echo ${TRAIN_DATA[i+1]} | cut -d "." -f 1`
  data_url=${TRAIN_DATA[i]}
  data_tgz=${TRAIN_DATA[i+1]}
  data_file=${TRAIN_DATA[i+2]}
  if [ ! -e ${OUTPUT_DIR_DATA}/${data_tgz} ]; then
    echo "Download "${data}
    wget -O ${OUTPUT_DIR_DATA}/${data_tgz} ${data_url}
  fi

  if [ ! -d ${OUTPUT_DIR_DATA}/${data} ]; then
    echo "Extract "${data}
    mkdir -p ${OUTPUT_DIR_DATA}/${data}
    tar -xvzf ${OUTPUT_DIR_DATA}/${data_tgz} -C ${OUTPUT_DIR_DATA}/${data}
  fi
  # concatenate all training data
  for l in ${LANG1} ${LANG2}; do
    for j in ${data_file}; do
      if [ $i -eq 0 ]; then
        cat ${OUTPUT_DIR_DATA}/${data}/$j.$l > ${OUTPUT_DIR_DATA}/train.$l
      else
        cat ${OUTPUT_DIR_DATA}/${data}/$j.$l >> ${OUTPUT_DIR_DATA}/train.$l
      fi
    done
  done
done

# Clone mosesdecoder
if [ ! -d ${OUTPUT_DIR}/mosesdecoder ]; then
  echo "Cloning moses for data processing"
  git clone https://github.com/moses-smt/mosesdecoder.git ${OUTPUT_DIR}/mosesdecoder
fi

# Extract develop and test data
dev_test_data=""
for ((i=0;i<${#DEV_TEST_DATA[@]};i+=4)); do
  data=`echo ${DEV_TEST_DATA[i+1]} | cut -d "." -f 1`
  data_url=${DEV_TEST_DATA[i]}
  data_tgz=${DEV_TEST_DATA[i+1]}
  data_lang1=${DEV_TEST_DATA[i+2]}
  data_lang2=${DEV_TEST_DATA[i+3]}
  if [ ! -e ${OUTPUT_DIR_DATA}/${data_tgz} ]; then
    echo "Download "${data}
    wget -O ${OUTPUT_DIR_DATA}/${data_tgz} ${data_url}
  fi

  if [ ! -d ${OUTPUT_DIR_DATA}/${data} ]; then
    echo "Extract "${data}
    mkdir -p ${OUTPUT_DIR_DATA}/${data}
    tar -xvzf ${OUTPUT_DIR_DATA}/${data_tgz} -C ${OUTPUT_DIR_DATA}/${data}
  fi

  for data_lang in $data_lang1 $data_lang2; do
    for j in `find ${OUTPUT_DIR_DATA}/${data} -regex ${data_lang}`; do
    data_dir=`dirname $j`
    data_file=`echo $j | awk -F '/' '{print $NF}'`
    data_out=`echo ${data_file} | cut -d '-' -f 1`  # newstest2016
    l=`echo ${data_file} | cut -d '.' -f 2`  # en
    dev_test_data="${dev_test_data}\|${data_out}"  # to make regexp
    if [ ! -e ${data_dir}/${data_out}.$l ]; then
      ${OUTPUT_DIR}/mosesdecoder/scripts/ems/support/input-from-sgm.perl \
        < $j > ${data_dir}/${data_out}.$l
      cp ${data_dir}/${data_out}.$l ${OUTPUT_DIR_DATA}
    fi
    done
  done
done

# Tokenize data
for l in ${LANG1} ${LANG2}; do
  for f in `ls ${OUTPUT_DIR_DATA}/*.$l | grep "\(train${dev_test_data}\)\.$l$"`; do
    f_base=${f%.*}  # dir/train dir/newstest2016
    f_out=$f_base.tok.$l
    if [ ! -e $f_out ]; then
      echo "Tokenize "$f
      ${OUTPUT_DIR}/mosesdecoder/scripts/tokenizer/tokenizer.perl -q -l $l -threads 8 < $f > $f_out
    fi
  done
done

# Clean data
for f in ${OUTPUT_DIR_DATA}/train.${LANG1} ${OUTPUT_DIR_DATA}/train.tok.${LANG1}; do
  f_base=${f%.*}  # dir/train dir/train.tok
  f_out=${f_base}.clean
  if [ ! -e $f_out.${LANG1} ] && [ ! -e $f_out.${LANG2} ]; then
    echo "Clean "${f_base}
    ${OUTPUT_DIR}/mosesdecoder/scripts/training/clean-corpus-n.perl $f_base ${LANG1} ${LANG2} ${f_out} 1 80
  fi
done

# Clone subword-nmt and generate BPE data
if [ ! -d ${OUTPUT_DIR}/subword-nmt ]; then
  git clone https://github.com/rsennrich/subword-nmt.git ${OUTPUT_DIR}/subword-nmt
fi

# Generate BPE data and vocabulary
for num_operations in 32000; do
  if [ ! -e ${OUTPUT_DIR_BPE_DATA}/bpe.${num_operations} ]; then
    echo "Learn BPE with ${num_operations} merge operations"
    cat ${OUTPUT_DIR_DATA}/train.tok.clean.${LANG1} ${OUTPUT_DIR_DATA}/train.tok.clean.${LANG2} | \
      ${OUTPUT_DIR}/subword-nmt/learn_bpe.py -s $num_operations > ${OUTPUT_DIR_BPE_DATA}/bpe.${num_operations}
  fi

  for l in ${LANG1} ${LANG2}; do
    for f in `ls ${OUTPUT_DIR_DATA}/*.$l | grep "\(train${dev_test_data}\)\.tok\(\.clean\)\?\.$l$"`; do
      f_base=${f%.*}  # dir/train.tok dir/train.tok.clean dir/newstest2016.tok
      f_base=${f_base##*/}  # train.tok train.tok.clean newstest2016.tok
      f_out=${OUTPUT_DIR_BPE_DATA}/${f_base}.bpe.${num_operations}.$l
      if [ ! -e $f_out ]; then
        echo "Apply BPE to "$f
        ${OUTPUT_DIR}/subword-nmt/apply_bpe.py -c ${OUTPUT_DIR_BPE_DATA}/bpe.${num_operations} < $f > $f_out
      fi
    done
  done

  if [ ! -e ${OUTPUT_DIR_BPE_DATA}/vocab.bpe.${num_operations} ]; then
    echo "Create vocabulary for BPE data"
    cat ${OUTPUT_DIR_BPE_DATA}/train.tok.clean.bpe.${num_operations}.${LANG1} ${OUTPUT_DIR_BPE_DATA}/train.tok.clean.bpe.${num_operations}.${LANG2} | \
      ${OUTPUT_DIR}/subword-nmt/get_vocab.py | cut -f1 -d ' ' > ${OUTPUT_DIR_BPE_DATA}/vocab.bpe.${num_operations}
  fi
done

# Adapt to the reader
for f in ${OUTPUT_DIR_BPE_DATA}/*.bpe.${num_operations}.${LANG1}; do
  f_base=${f%.*}  # dir/train.tok.clean.bpe.32000 dir/newstest2016.tok.bpe.32000
  f_out=${f_base}.${LANG1}-${LANG2}
  if [ ! -e $f_out ]; then
    paste -d '\t' $f_base.${LANG1} $f_base.${LANG2} > $f_out
  fi
done
if [ ! -e ${OUTPUT_DIR_BPE_DATA}/vocab_all.bpe.${num_operations} ]; then
  sed '1i\<s>\n<e>\n<unk>' ${OUTPUT_DIR_BPE_DATA}/vocab.bpe.${num_operations} > ${OUTPUT_DIR_BPE_DATA}/vocab_all.bpe.${num_operations}
fi

echo "All done."
