#binaries from website
RELATE_DIR=`pwd`/../../../relate
#git clone https://github.com/leospeidel/relate_lib.git
#cd relate_lib && mkdir -p build && cd build
#cmake .. && make && cd ../..
RELATE_LIB=`pwd`/../../../relate_lib 


NE="20000" #haploid
MU="1.25e-8"
SEED="1024"
ID="chr1"
SEQLEN=1000000
SAMPLES=100

WORK_DIR=`pwd`/sim_$SEED
IN_DIR=$WORK_DIR/relate_inputs
OUT_DIR=$WORK_DIR/relate_outputs
mkdir -p $WORK_DIR
mkdir -p $IN_DIR
mkdir -p $OUT_DIR

# simulate data
cd $WORK_DIR
printf '
import msprime
ne = %s
mu = %s
seed = %s
id = "%s"
seqlen = %s
samples = %s
ts = msprime.sim_ancestry(
  samples=samples,
  ploidy=1,
  recombination_rate=1e-8,
  population_size=ne,
  sequence_length=seqlen,
  random_seed=seed,
)
ts = msprime.sim_mutations(
  ts, rate=mu, random_seed=seed
)
ts.dump(f"{id}.trees")
ts.write_vcf(
  open(f"{id}.vcf", "w"), 
  contig_id=id,
  individual_names=[f"HAP{i}" for i in range(samples)],
  position_transform=lambda p: [x-1 for x in p],
)
' $NE $MU $SEED $ID $SEQLEN $SAMPLES | python3 && gzip -f $ID.vcf

cd $IN_DIR

#reassign reference alleles
bioawk -cvcf -H '{$alt="G"; $ref="A"; print}' ../$ID.vcf.gz >$ID.vcf

#dump into haplotypes
$RELATE_DIR/bin/RelateFileFormats \
  --mode ConvertFromVcf --haps $ID.haps \
  --sample $ID.samples -i $ID

#hapmap
printf '
cl <- %s
cat("Position(bp) Rate(cM/Mb) Map(cM)\n")
cat("0 1.0 0.0\n")
cat(as.integer(cl), "0.0", cl/1e6, "\n")
' $SEQLEN | R --slave >$ID.hapmap

#population labels
awk 'NR==1 {print "sample\tpopulation\tgroup\tsex"} NR>2{pop=$1; sub(/[0-9]+/, "", pop); print $1"\t"pop"\t"pop"\t1"}' $ID.samples >$ID.poplabels

#ancestral states
printf '
cat(">%s", "\n", sep="")
cat(rep("A", %s), "\n", sep="")
' $ID $SEQLEN | R --slave >$ID.anc.fa

#accessibility mask
printf '
cat(">%s", "\n", sep="")
cat(rep("P", %s), "\n", sep="")
' $ID $SEQLEN | R --slave >$ID.mask.fa

#infer trees
$RELATE_DIR/scripts/PrepareInputFiles/PrepareInputFiles.sh \
  --haps $ID.haps \
  --sample $ID.samples \
  --poplabels $ID.poplabels \
  --ancestor $ID.anc.fa \
  --mask $ID.mask.fa \
  -o $ID
$RELATE_DIR/bin/Relate --mode All -m $MU -N $NE \
  --haps $ID.haps.gz --sample $ID.sample.gz --annot $ID.annot \
  --dist $ID.dist.gz --map $ID.hapmap -o $ID

cd ..

#reinfer branch lengths under nonconstant population size
$RELATE_DIR/scripts/EstimatePopulationSize/EstimatePopulationSize.sh \
  -i $IN_DIR/$ID -o $OUT_DIR/$ID -m $MU \
  --poplabels $IN_DIR/$ID.poplabels \
  --threshold 0.5 \
  --years_per_gen 1 \
  --num_iter 1 \
  --threads 4

# convert to tree sequence with edges linked across trees
$RELATE_LIB/bin/Convert --mode ConvertToTreeSequence \
  --anc $OUT_DIR/$ID.anc.gz --mut $OUT_DIR/$ID.mut.gz --iterations 1000 --compress -o $OUT_DIR/$ID
