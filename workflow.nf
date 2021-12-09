#!/usr/bin/env nextflow

//params.OUTDIR = "gs://prj-int-dev-covid19-nf-gls/illumina-porting-workdir/results"
params.SARS2_FA = "gs://prj-int-dev-covid19-nf-gls/illumina-porting-workdir/data/ref/NC_045512.2.fa"
params.SARS2_FA_FAI = "gs://prj-int-dev-covid19-nf-gls/illumina-porting-workdir/data/ref/NC_045512.2.fa.fai"
//params.INDEX = "gs://prj-int-dev-covid19-nf-gls/illumina-porting-workdir/data/illumina.index.tsv"
//params.STOREDIR = "gs://prj-int-dev-covid19-nf-gls/noncovid/storeDir"

Channel
    .fromPath(params.INDEX)
    .splitCsv(header:true, sep:'\t')
    .map{ row-> tuple(row.run_accession, 'ftp://'+row.fastq_ftp.split(';')[0], 'ftp://'+row.fastq_ftp.split(';')[1]) }
    .set { samples_ch }

process illumina_pipeline {
    cpus 6
    memory '8 GB'
    container 'milm/bio-rep:latest'
    publishDir params.OUTDIR, mode:'copy'
    storeDir params.STOREDIR

    input:
    tuple run_id, file(input_file_1), file(input_file_2) from samples_ch
    path sars2_fasta from params.SARS2_FA
    path sars2_fasta_fai from params.SARS2_FA_FAI

    output:
    file("${run_id}_output.tar.gz")
    file("${run_id}_output/${run_id}.annot.vcf.gz")
    file("${run_id}_output/${run_id}.bam")
    file("${run_id}_output/${run_id}.coverage.gz")
    file("${run_id}_output/${run_id}.stat")
    file("${run_id}_output/${run_id}.vcf.gz")
    file("${run_id}_output/${run_id}_consensus.fasta.gz")
    file("${run_id}_output/${run_id}_filtered.vcf.gz")
    file("${run_id}_output/${run_id}_trim_summary")

    script:
    """
    wget -t 0 -O ${run_id}_1.fastq.gz \$(cat ${input_file_1})
    wget -t 0 -O ${run_id}_2.fastq.gz \$(cat ${input_file_2})

    trimmomatic PE ${run_id}_1.fastq.gz ${run_id}_2.fastq.gz ${run_id}_trim_1.fq \
    ${run_id}_trim_1_un.fq ${run_id}_trim_2.fq ${run_id}_trim_2_un.fq \
    -summary ${run_id}_trim_summary -threads ${task.cpus} \
    SLIDINGWINDOW:5:30 MINLEN:50

    bwa index ${sars2_fasta}
    bwa mem -t ${task.cpus} ${sars2_fasta} ${run_id}_trim_1.fq ${run_id}_trim_2.fq | samtools view -bF 4 - | samtools sort - > ${run_id}_paired.bam
    bwa mem -t ${task.cpus} ${sars2_fasta} <(cat ${run_id}_trim_1_un.fq ${run_id}_trim_2_un.fq) | samtools view -bF 4 - | samtools sort - > ${run_id}_unpaired.bam
    samtools merge ${run_id}.bam ${run_id}_paired.bam ${run_id}_unpaired.bam
    rm ${run_id}_paired.bam ${run_id}_unpaired.bam

    samtools mpileup -a -A -Q 30 -d 8000 -f ${sars2_fasta} ${run_id}.bam > ${run_id}.pileup

    cat ${run_id}.pileup | awk '{print \$2,","\$3,","\$4}' > ${run_id}.coverage

    samtools index ${run_id}.bam
    lofreq indelqual --dindel ${run_id}.bam -f ${sars2_fasta} -o ${run_id}_fixed.bam
    samtools index ${run_id}_fixed.bam
    lofreq call-parallel --no-default-filter --call-indels --pp-threads ${task.cpus} -f ${sars2_fasta} -o ${run_id}.vcf ${run_id}_fixed.bam
    lofreq filter --af-min 0.25 -i ${run_id}.vcf -o ${run_id}_filtered.vcf
    bgzip ${run_id}.vcf
    bgzip ${run_id}_filtered.vcf
    tabix ${run_id}.vcf.gz
    bcftools stats ${run_id}.vcf.gz > ${run_id}.stat

    zcat ${run_id}.vcf | sed "s/^NC_045512.2/NC_045512/" > ${run_id}.newchr.vcf
    java -Xmx4g -jar /data/tools/snpEff/snpEff.jar -q -no-downstream -no-upstream -noStats sars.cov.2 ${run_id}.newchr.vcf > ${run_id}.annot.vcf

    python3 /vcf_to_consensus.py -dp 10 -af 0.25 -v ${run_id}.vcf.gz -d ${run_id}.coverage -o ${run_id}_consensus.fasta -n ${run_id} -r ${sars2_fasta}
    bgzip ${run_id}_consensus.fasta

    bgzip ${run_id}.coverage
    bgzip ${run_id}.annot.vcf
    mkdir -p ${run_id}_output

    fastqc ${run_id}_1.fastq.gz
    fastqc ${run_id}_2.fastq.gz
    fastqc ${run_id}_trim_1.fq
    fastqc ${run_id}_trim_2.fq
    fastqc ${run_id}_trim_1_un.fq
    fastqc ${run_id}_trim_2_un.fq

    mv ${run_id}.annot.vcf.gz ${run_id}.bam ${run_id}.coverage.gz ${run_id}.stat ${run_id}.vcf.gz \
        ${run_id}_consensus.fasta.gz ${run_id}_filtered.vcf.gz ${run_id}_trim_summary \
        ${run_id}_1_fastqc.html ${run_id}_2_fastqc.html ${run_id}_trim_1_fastqc.html ${run_id}_trim_2_fastqc.html \
        ${run_id}_trim_1_un_fastqc.html ${run_id}_trim_2_un_fastqc.html ${run_id}_output
    tar -zcvf ${run_id}_output.tar.gz ${run_id}_output
    """
}
