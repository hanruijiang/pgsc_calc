process FILTER_VARIANTS {
    // labels are defined in conf/modules.config
    label 'process_low'
    label 'plink2' // controls conda, docker, + singularity options

    tag "$meta.id $meta.build"

    conda (params.enable_conda ? "${task.ext.conda}" : null)

    container "${ workflow.containerEngine == 'singularity' &&
        !task.ext.singularity_pull_docker_container ?
        "${task.ext.singularity}${task.ext.singularity_version}" :
        "${task.ext.docker}${task.ext.docker_version}" }"

    input:
    tuple val(meta), path(shared), path(ref_geno), path(ref_pheno), path(ref_var),
        path(ld), path(king)

    output:
    tuple val(build), path("*_reference.pgen"), path("*_reference.psam"), path("*_reference.pvar.zst"), emit: ref
    tuple val(build), path("*thinned.prune.in.gz"), emit: prune_in
    path "versions.yml", emit: versions

    script:
    def mem_mb = task.memory.toMega() // plink is greedy
    // dynamic input option
    def input = (meta.is_pfile) ? '--pfile vzs' : '--bfile vzs'
    build = meta.subMap('build')
    """
    # 1. Get QC'd variant set & unrelated samples from REFERENCE data for PCA --

    # ((IS_MA_REF == FALSE) && (IS_MA_TARGET == FALSE)) && (((IS_INDEL == FALSE) && (STRANDAMB == FALSE)) || ((IS_INDEL == TRUE) && (SAME_REF == TRUE)))
    awk '(((\$6 == 0) && (\$9 == 0)) && (((\$4 == 0) && (\$5 == 0)) || ((\$4 == 1) && (\$10 == 1)))) {print \$2}' <(zcat $shared) | gzip -c > shared.txt.gz

    plink2 \
            --threads $task.cpus \
            --memory $mem_mb \
            --pfile ${ref_geno.simpleName} vzs \
            --remove $king \
            --extract shared.txt.gz \
            --max-alleles 2 \
            --snps-only just-acgt \
            --rm-dup exclude-all \
            --geno 0.1 \
            --mind 0.1 \
            --maf 0.01 \
            --hwe 0.000001 \
            --make-pgen vzs \
            --allow-extra-chr --autosome \
            --out ${meta.build}_reference

    # 2. LD-thin variants in REFERENCE (filtered variants & samples) for input
    # into PCA -----------------------------------------------------------------
    plink2 \
            --threads $task.cpus \
            --memory $mem_mb \
            --pfile vzs ${meta.build}_reference \
            --indep-pairwise 1000 50 0.05 \
            --exclude range $ld \
            --out ${ref_geno.simpleName}_thinned

    gzip *.prune.in *.prune.out

    cat <<-END_VERSIONS > versions.yml
    ${task.process.tokenize(':').last()}:
        plink2: \$(plink2 --version 2>&1 | sed 's/^PLINK v//; s/ 64.*\$//' )
    END_VERSIONS
    """
}
