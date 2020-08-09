## Population genetic analysis of Varroa on native and introduced hosts
from scripts.split_fasta_regions import split_fasta
from snakemake.utils import R
import getpass

localrules: getHaps, all

## Set path for input files and fasta reference genome
readDir = "/bucket/MikheyevU/Maeva/nugen_snps/data/reads"
outDir = "/flash/MikheyevU/Maeva/nugen-results/data"
refDir = "/bucket/MikheyevU/Maeva/nugen_snps/ref2019" 
SCRATCH  = "/flash/MikheyevU/Maeva/scratch" 

## Varroa destructor and V. jacobosni references
vdRef = refDir + "/destructor/vdes_3_refseqmtDNA.fasta"
vdBowtieIndex = refDir + "/destructor/vdes_3_refseqmtDNA"

vdmtDNA = refDir + "/destructor/mtDNA/AJ493124.fasta"
vdmtBowtieIndex = refDir + "/destructor/mtDNA/vdnavajas"

## Apis mellifera and A. cerana references
hostBeeMtBowtieIndex = refDir + "/bees/mtdna/hostbeemito"
hostBeeBowtieIndex = refDir + "/bees/hostbee"

CHROMOSOMES = ["NW_019211454.1", "NW_019211455.1", "NW_019211456.1", "NW_019211457.1", "NW_019211458.1", "NW_019211459.1", "NW_019211460.1"]
KCLUSTERS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
RUNS = ["run1", "run2", "run3", "run4", "run5"]

## Input fastq.g:xz files generated by whole genome sequencing from 44 individuals
SAMPLES, = glob_wildcards(readDir + "/{sample}_R1_001.fastq.gz")

## Creation of parameters for splitting reference genome and cut off computation time
SPLITS = range(200)
REGIONS = split_fasta(vdRef, len(SPLITS))  # dictionary with regions to be called, with keys in SPLITS
Q = (20, 40) # 99 and 99.99% mapping accuracy
for region in REGIONS:
	for idx,i in enumerate(REGIONS[region]):
		REGIONS[region][idx] = " -r " + str(i)

SPLITSMT = range(10)
REGIONSMT = split_fasta(vdmtDNA, len(SPLITSMT))  # dictionary with regions to be called, with keys in SPLITS
Q = (20, 40) # 99 and 99.99% mapping accuracy
for regionmt in REGIONSMT:
        for idx,i in enumerate(REGIONSMT[regionmt]):
                REGIONSMT[regionmt][idx] = " -r " + str(i)

## Pseudo rule for build-target
rule all:
	input: 	expand(outDir + "/meta/hosts/hosts-{q}.txt", q = 20),
		expand(outDir + "/sketches/{sample}.fastq.gz", sample = SAMPLES),
		#expand(outDir + "/alignments/bowtie2/{sample}.bam", sample = SAMPLES),
		#expand(outDir + "/alignments/ngm/{sample}.bam", sample = SAMPLES),
		expand(outDir + "/alignments/ngm_mtDNA/{sample}.bam", sample = SAMPLES),
		#expand(outDir + "/meta/align_ngm/{sample}.txt", sample = SAMPLES),
		#expand(outDir + "/meta/align_bowtie2/{sample}.txt", sample = SAMPLES),
		#outDir + "/var/bowtie2/raw.WGS.vcf"
		outDir + "/var/bowtie2/freebayes.target.vcf"
		#expand(outDir + "/var/ngm_mtDNA/consensus/{sample}.fasta", sample = SAMPLES),
		#outDir + "/var/ngm/filterbialmaf001_7chrom_sorted.vcf.gz"
		#expand(outDir + "/ngsadmix/filtered644/{run}/filtered644_{kcluster}.fopt.gz", kcluster = KCLUSTERS, run = RUNS)

########################################
##### CHECK AND REMOVE HOST GENOME #####
########################################

rule checkHost:
	input:
		read1 = readDir + "/{sample}_R1_001.fastq.gz",
		read2 = readDir + "/{sample}_R2_001.fastq.gz",
	output:
		temp(outDir + "/meta/hosts/{sample}-{q}.txt")
	threads: 12
	shell:
		"""
		bowtie2 -p {threads} -x {hostBeeMtBowtieIndex} -1  {input.read1} -2 {input.read2} | samtools view -S -q {wildcards.q}  -F4 - | awk -v mellifera=0 -v cerana=0 -v sample={wildcards.sample} '$3~/^L/ {{mellifera++; next}}  {{cerana++}} END {{if(mellifera>cerana) print sample"\\tmellifera\\t"cerana"\\t"mellifera ; else print sample"\\tcerana\\t"cerana"\\t"mellifera}}' > {output}
		"""

rule combineHost:
	input:
		expand(outDir + "/meta/hosts/{sample}-{{q}}.txt", sample = SAMPLES)
	output:
		outDir + "/meta/hosts/hosts-{q}.txt"
	shell:
		"""
		(echo -ne "id\\thost\\tcerana\\tmellifera\\n"; cat {input}) > {output}
		"""

rule removeHost:
	input:
		read1 = readDir + "/{sample}_R1_001.fastq.gz",
		read2 = readDir + "/{sample}_R2_001.fastq.gz",
	threads: 12
	output: temp(outDir + "/sketches/{sample}.fastq.gz")
	shell: 
		"""
		bowtie2 -p {threads} -x {hostBeeBowtieIndex} -1  {input.read1} -2 {input.read2}  | samtools view -S -f12 | awk '{{print "@"$1"\\n"$10"\\n+\\n"$11}}' | gzip > {output}
		"""
		

#############################
##### WHOLE GENOME CALL #####
#############################

## Here reads will be mapped using either bowtie2 or ngm, then test which one is the best
## on whole genome
rule bowtie2:
	input:
		read1 = readDir + "/{sample}_R1_001.fastq.gz",
		read2 = readDir + "/{sample}_R2_001.fastq.gz",
	threads: 12
	output: 
		alignment = temp(outDir + "/alignments/bowtie2/{sample}.bam"), 
		index = temp(outDir + "/alignments/bowtie2/{sample}.bam.bai"),
		read1 = outDir + "/reads_unmapped/{sample}.1",
		read2 = outDir + "/reads_unmapped/{sample}.2"

	shell:
		"""
		bowtie2 -p {threads} --very-sensitive-local --sam-rg ID:{wildcards.sample} --sam-rg LB:Nextera --sam-rg SM:{wildcards.sample} --sam-rg PL:ILLUMINA  --un-conc-gz  {outDir}/reads_unmapped/{wildcards.sample} -x {vdBowtieIndex} -1 {input.read1} -2 {input.read2} | samtools view -Su - | samtools sort - -m 2G -T {SCRATCH}/bowtie2/{wildcards.sample} -o - | samtools rmdup - - | variant - -m 500 -b -o {output.alignment}
		samtools index {output.alignment}
		"""


rule nextgenmap:
	input:
		read1 = readDir + "/{sample}_R1_001.fastq.gz",
		read2 = readDir + "/{sample}_R2_001.fastq.gz",
	threads: 6
	output: 
		alignment = temp(outDir + "/alignments/ngm/{sample}.bam"), 
		index = temp(outDir + "/alignments/ngm/{sample}.bam.bai")
	shell:
		"""
		ngm -t {threads} -b  -1 {input.read1} -2 {input.read2} -r {vdRef} --rg-id {wildcards.sample} --rg-sm {wildcards.sample} --rg-pl ILLUMINA --rg-lb {wildcards.sample} | samtools sort - -m 10G -T {SCRATCH}/ngm/{wildcards.sample} -o - | samtools rmdup - - | variant - -m 500 -b -o {output.alignment}
		samtools index {output.alignment}
		"""

rule statsbamngm:
        input:
                alignment = temp(outDir + "/alignments/ngm/{sample}.bam")
        output:
                temp(outDir + "/meta/align_ngm/{sample}.txt")
        shell:
                """
		echo {wildcards.sample} > {output}
		samtools depth -a {input.alignment}  |  awk '{{sum+=$3}} END {{ print "Average = ",sum/NR}}' >> {output}
		samtools flagstat {input.alignment} >> {output}
		"""

rule statsbambowtie2:
        input:
                alignment = temp(outDir + "/alignments/bowtie2/{sample}.bam")
        output:
                temp(outDir + "/meta/align_bowtie2/{sample}.txt")
        shell:
                """
                echo {wildcards.sample} > {output}
                samtools depth -a {input.alignment}  |  awk '{{sum+=$3}} END {{ print "Average = ",sum/NR}}' >> {output}
                samtools flagstat {input.alignment} >> {output}
                """

rule freeBayes_WGS:
        input:
                expand(outDir + "/alignments/bowtie2/{sample}.bam", sample = SAMPLES)
        output:
                temp(outDir + "/var/bowtie2/split_WGS/freebayes.{region}.vcf")
        params:
                span = lambda wildcards: REGIONS[wildcards.region],
                bams = lambda wildcards, input: os.path.dirname(input[0]) + "/*.bam",
                missing = lambda wildcards, input: len(input) * 0.9
        shell:
                """
                #for i in {params.bams}; do name=$(basename $i .bam); if [[ $name == VJ* ]] ; then echo $name VJ; else echo $name VD; fi ; done > {outDir}/var/pops.txt
                freebayes --min-alternate-fraction 0.2 --use-best-n-alleles 4 -m 5 -q 5 --samples /flash/MikheyevU/Maeva/nugen-results/data/list/WGS_48ind.txt -b {params.bams} {params.span} -f {vdRef} | vcffilter  -f "QUAL > 20" > {output}
                """


rule mergeVCF_WGS:
        input:
                expand(outDir + "/var/bowtie2/split_WGS/freebayes.{region}.vcf", region = REGIONS)
        output:
                temp(outDir + "/var/bowtie2/raw.WGS.vcf")
        shell:
                """
                (grep "^#" {input[0]} ; cat {input} | grep -v "^#" ) | vcfuniq  > {output}
                """


rule freeBayes_Nugen:
        input:
                expand(outDir + "/alignments/bowtie2/{sample}.bam", sample = SAMPLES)
        output:
                temp(outDir + "/var/bowtie2/freebayes.target.vcf")
        params:
                bams = lambda wildcards, input: os.path.dirname(input[0]) + "/*.bam",
                missing = lambda wildcards, input: len(input) * 0.9
        shell:
                """
                #for i in {params.bams}; do name=$(basename $i .bam); if [[ $name == VJ* ]] ; then echo $name VJ; else echo $name VD; fi ; done > {outDir}/var/pops.txt
                freebayes --min-alternate-fraction 0.2 --use-best-n-alleles 4 -m 5 -q 5 --targets /flash/MikheyevU/Maeva/nugen-results/data/list/regions_NUGEN.txt --populations /flash/MikheyevU/Maeva/nugen-results/data/list/pops_host_96ind.txt -b {params.bams} -f {vdRef} | vcffilter  -f "QUAL > 20" > {output}
                """

rule filterVCF_1:
	input:
		rawvcf = outDir + "/var/ngm/raw.vcf"
	output:
		vcf = outDir + "/var/ngm/raw.mac3dp3noindel.vcf",
		ready2bcf = outDir + "/var/ngm/raw.mac3dp3noindel.vcf.gz",
		ready2tbi = outDir + "/var/ngm/raw.mac3dp3noindel.vcf.gz.tbi"
	shell:
		"""
                vcftools --vcf {input.rawvcf} --remove-indels --minDP 3 --minQ 30 --mac 3 --recode --recode-INFO-all --out /var/ngm/raw.mac3dp3noindel
		bgzip -c {output.vcf} > {output.ready2bcf}
		tabix -p vcf {output.ready2bcf}
		"""

rule filterVCF_2:
        input:
                outDir + "/var/ngm/raw.mac3dp3noindel.vcf.gz"
        output:
                vcffilter = outDir + "/var/ngm/filterbialmaf001_7chrom.vcf",
		ready2bcf = outDir + "/var/ngm/filterbialmaf001_7chrom.vcf.gz",
                ready2tbi = outDir + "/var/ngm/filterbialmaf001_7chrom.vcf.gz.tbi"
	shell:
                """
                module load vcftools/0.1.16
                vcftools --gzvcf {input} --max-alleles 2 --maf 0.01 --chr NW_019211454.1 --chr NW_019211455.1 --chr NW_019211456.1 --chr NW_019211457.1 --chr NW_019211458.1 --chr NW_019211459.1 --chr NW_019211460.1 --recode --recode-INFO-all --out filterbialmaf001_7chrom
                bgzip -c {output.vcffilter} > {output.ready2bcf}
                tabix -p vcf {output.ready2bcf}
		"""


#########################################
##### ANALYSIS POST VARIANT CALLING #####
#########################################

#### ALL SPECIES COUNFOUNDED

rule sortvcf:
        input:  variant = outDir + "/var/ngm/filterbialmaf001_7chrom.vcf.gz", list = outDir + "/list/ngslist644.txt"
        output: outDir + "/var/ngm/filterbialmaf001_7chrom_sorted.vcf.gz"
        shell:
                """
                bcftools view -Oz --samples-file {input.list} {input.variant} > {output}
                """

rule vcf2GL:
        input:  outDir + "/var/ngm/filterbialmaf001_7chrom_sorted.vcf.gz"
        output: temp(outDir + "/ngsadmix/filtered644/{chromosome}.BEAGLE.GL")
        shell:
                """
		module load vcftools/0.1.16
                vcftools --gzvcf {input} --chr {wildcards.chromosome} --out /work/MikheyevU/Maeva/world-varroa/data/ngsadmix/filtered644/{wildcards.chromosome} --max-missing 1 --BEAGLE-GL
                """

rule mergeGL:
        input: expand(outDir + "/ngsadmix/filtered644/{chromosome}.BEAGLE.GL", chromosome = CHROMOSOMES)
        output: outDir + "/ngsadmix/filtered644/sevenchr.BEAGLE.GL"
        shell:
                """
                (head -1 {input[0]}; for i in {input}; do cat $i | sed 1d; done) > {output}
                """

rule NGSadmix:
        input: outDir + "/ngsadmix/filtered644/sevenchr.BEAGLE.GL"
        threads: 12
        output: temp(outDir + "/ngsadmix/filtered644/{run}/raw366_{kcluster}.fopt.gz")
        shell:
                """
                NGSadmix -P {threads} -likes {input} -K {wildcards.kcluster} -outfiles /work/MikheyevU/Maeva/world-varroa/data/ngsadmix/filtered644/{wildcards.run}/filtered644_{wildcards.kcluster} -minMaf 0.1
                """

#############################
##### MITOCHONDRIAL DNA #####
#############################

rule mtDNA_ngm:
        input:
                read1 = readDir + "/{sample}_R1_001.fastq.gz",
                read2 = readDir + "/{sample}_R2_001.fastq.gz",
        threads: 12
        output:
                alignment = temp(outDir + "/alignments/ngm_mtDNA/{sample}.bam"),
                index = temp(outDir + "/alignments/ngm_mtDNA/{sample}.bam.bai")
        shell:
                """
                ngm -t {threads} -b  -1 {input.read1} -2 {input.read2} -r {vdmtDNA} --rg-id {wildcards.sample} --rg-sm {wildcards.sample} --rg-pl ILLUMINA --rg-lb {wildcards.sample} | samtools view -Su -F4 -q10 | samtools sort - -m 55G -T {SCRATCH}/ngm_mtDNA/{wildcards.sample} -o - | samtools rmdup - - | variant - -m 1000 -b -o {output.alignment}
                samtools index {output.alignment}
                """

rule mtDNA_freeBayes:
        input:
                expand(outDir + "/alignments/ngm_mtDNA/{sample}.bam", sample = SAMPLES)
        output:
                temp(outDir + "/var/ngm_mtDNA/split_mtDNA/freebayes_mtDNA.{regionmt}.vcf")
        params:
                span = lambda wildcards: REGIONSMT[wildcards.regionmt],
                bams = lambda wildcards, input: os.path.dirname(input[0]) + "/*.bam",
        shell:
                """
		module load freebayes/1.3.1 vcftools/0.1.16 vcflib/1.0.0-rc1
                freebayes --ploidy 2 --min-alternate-fraction 0.2 --use-best-n-alleles 4 -m 5 -q 5 --populations {outDir}/list/pops_sphost_world644.txt -b {params.bams} {params.span} -f {vdmtDNA} | vcffilter -f "QUAL > 20" > {output}
                """

rule mtDNA_mergeVCF:
        input:
                expand(outDir + "/var/ngm_mtDNA/split_mtDNA/freebayes_mtDNA.{regionmt}.vcf", regionmt = REGIONSMT)
        output:
                mergevcf = outDir + "/var/ngm_mtDNA/raw_mtDNA.vcf",
		bcfready = outDir + "/var/ngm_mtDNA/raw_mtDNA.vcf.gz"
        shell:
                """
                (grep "^#" {input[0]} ; cat {input} | grep -v "^#" ) | vcfuniq  > {output.mergevcf}
		bgzip -c {output.mergevcf} > {output.bcfready}
		tabix -p vcf {output.bcfready}
                """


rule mtDNA_consensus:
	input:	outDir + "/var/ngm_mtDNA/raw_mtDNA.vcf.gz"
	output:	temp(outDir + "/var/ngm_mtDNA/consensus/{sample}.fasta")
	shell:
		"""
		bcftools consensus --iupac-codes --sample {wildcards.sample} --fasta-ref {vdmtDNA} --output {output} {input}
		"""
