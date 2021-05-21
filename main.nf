if (params.input) { ch_input = file(params.input, checkIfExists: true) }
else { exit 1, "Samplesheet file not specified!" }

if (params.gtf) { ch_ref = file(params.gtf, checkIfExists: true) }
else { exit 1, "Reference Annotation file not specified!" }

if (params.fa) { ch_fa = file(params.fa, checkIfExists: true) }
else { exit 1, "Reference Genome file not specified!" }

params.outdir = "results"
params.readCount = 5
params.sampleNumber = 1

def logHeader() {
    // Log colors ANSI codes
    c_dim = "\033[2m";
    c_green = "\033[0;32m";
    c_purple = "\033[0;35m";
    c_reset = "\033[0m";

    return """-${c_dim}----------------------------------------${c_reset}-
${c_green}    ___    _   ___   _________  __ ___ 
   /   |  / | / / | / / ____/ |/ //   |
  / /| | /  |/ /  |/ / __/  |   // /| |
 / ___ |/ /|  / /|  / /___ /   |/ ___ |
/_/  |_/_/ |_/_/ |_/_____//_/|_/_/  |_|
                                       ${c_reset}
-${c_dim}----------------------------------------${c_reset}-
${c_purple}github.com/mlorthiois/ANNEXA${c_reset}
Reference Annotation : ${params.gtf}
Reference Genome     : ${params.fa}
Input Samplesheet    : ${params.input}
Bambu read count     : ${params.readCount}
Bambu sample number  : ${params.sampleNumber}
-${c_dim}----------------------------------------${c_reset}-
""".stripIndent()
}

log.info logHeader()

///////////////////////////////////////////////////////////////////////////
Channel
    .fromPath(ch_input)
    .splitCsv(header:true, sep:',')
    .map { row -> file(row.sample) }
    .set { ch_bam }


process BAMBU {
  publishDir "$params.outdir/bambu", mode: 'copy'
  cpus 8
  memory '40GB'
  conda 'envs/bambu.yml'

  input:
  file '*.bam' from ch_bam.collect()
  file ref from ch_ref
  file fa from ch_fa

  output:
  file 'extended_annotations.gtf' into ch_bambu_gtf
  file 'counts_transcript.txt' into ch_bambu_tx
  file 'counts_gene.txt' into ch_bambu_gene

  """
  bambu_counts.R \
    --tag=. \
    --ncore=8 \
    --sampleNumber=${params.sampleNumber} \
    --readCount=${params.readCount} \
    --annotation=${ref} \
    --fasta=${fa} \
    *.bam
  """
}

process SPLIT_BAMBU {
  input:
  file input from ch_bambu_gtf

  output:
  file("known.gtf") into ch_known
  file("novel.gtf") into ch_novel

  """
  sed 's/*/./g' ${input} > tmp.gtf
  split_merged_gtf.sh tmp.gtf
  """
}

process FEELNC {
    publishDir "$params.outdir", mode: 'copy', saveAs: { filename -> "feelnc/${filename.split('/')[-1]}" }
    conda 'envs/feelnc.yml'
    memory '16 GB'

    input:
    file ref from ch_ref
    file fa from ch_fa
    file gtf from ch_novel

    output:
    file("feelnc_codpot_out/new.lncRNA.gtf") into ch_feelnc_codpot_lncRNA
    file("feelnc_codpot_out/new.mRNA.gtf") into ch_feelnc_codpot_mRNA

    shell:
    """
    FEELnc_codpot.pl \
        -i $gtf \
        -a $ref \
        -g $fa \
        -b transcript_biotype=protein_coding \
        -b transcript_status=KNOWN \
        --numtx=2000,2000 \
        --mode=shuffle \
        -o new
    """
}

process RESTORE_ATTRIBUTES_FROM_REF {
  input:
  file ref from ch_ref
  file known from ch_known

  output:
  file("known.restored.gtf") into ch_known_restored

  """
  restore_from_ref.py -gtf $known -ref $ref > known.restored.gtf
  """
}

process JOIN_FEELNC_WITH_BIOTYPE {
  publishDir "$params.outdir/feelnc", mode: 'copy'

  input:
  file mRNA from ch_feelnc_codpot_mRNA
  file lncRNA from ch_feelnc_codpot_lncRNA

  output:
  file("feelnc.combined.gtf") into ch_feelnc_combined

  """
  merge_feelnc.py -lncRNA ${lncRNA} -mRNA ${mRNA} > feelnc.combined.gtf
  """
}

process FORMAT_NOVEL_KNOWN {
  publishDir "$params.outdir/final", mode: 'copy'

  input:
  file known from ch_known_restored
  file novel from ch_feelnc_combined

  output:
  file("extented_annotations.gtf") into ch_final

  """
  cat $known $novel | GTF.py format > extented_annotations.gtf
  """
}

process NORMALIZE_GENE_COUNTS {
  publishDir "$params.outdir/DESeq2", mode: 'copy'
  conda 'envs/deseq.yml'

  input:
  file gene_counts from ch_bambu_gene
  file input from ch_input

  output:
  file "normalization.pdf" optional true into ch_norm_pdf
  file "counts_gene.normalized.vsd.csv" into ch_norm_gene

  """
  deseq_normalization.R ${input} ${gene_counts}
  """
}
  

process QC_EXTENDED_GTF {
  conda 'envs/qc.yml'
  publishDir "$params.outdir/qc", mode: 'copy'

  input:
  file gtf from ch_final
  file ref from ch_ref
  file counts_gene from ch_norm_gene
  file counts_transcript from ch_bambu_tx

  output:
  file "gene.stats" into ch_gene_stats
  file "transcript.stats" into ch_tx_stats
  file "exon.stats" into ch_exon_stats
  file "qc_gtf.pdf" into ch_qc_pdf

  """
  qc_gtf.py -gtf ${gtf} \
    -c_gene ${counts_gene} \
    -c_tx ${counts_transcript} \
    -ref ${ref}
  qc.R
  """
}
