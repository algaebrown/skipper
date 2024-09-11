HEADER = '/tscc/nfs/home/hsher/bin/Roulette/header.hr'
RENAME='/tscc/nfs/home/hsher/projects/oligoCLIP/utils/rename_chr.txt'
ROULETTE_DIR=Path('/tscc/nfs/home/hsher/ps-yeolab5/roulette/')
GNOMAD_DIR=Path('/tscc/nfs/home/hsher/ps-yeolab5/gnomAD/v4/')
CLINVAR_VCF='/tscc/projects/ps-yeolab5/hsher/clinvar/clinvar.vcf.gz'
VEP_CACHEDIR='/tscc/nfs/home/hsher/scratch/vep_cache/'
import pandas as pd
locals().update(config)

rule filter_roulette_for_high:
    input:
        vcf=ROULETTE_DIR/'{chr_number}_rate_v5.2_TFBS_correction_all.vcf.bgz',
        header=HEADER
    output:
        reheader = temp(ROULETTE_DIR/'{chr_number}_rate_v5.2_TFBS_correction_all.header.vcf'),
        filtered = temp(ROULETTE_DIR/'{chr_number}_rate_v5.2_TFBS_correction_all.header.filtered.vcf'),
    container:
        "docker://brianyee/bcftools:1.17"
    threads: 1
    params:
        error_file = "stderr/filter_roulette.{chr_number}",
        out_file = "stdout/filter_roulette.{chr_number}",
        run_time = "1:20:00",
        cores = 1,
        memory = 40000,
    shell:
        """
        bcftools reheader -h {input.header} \
            {input.vcf} > {output.reheader}
        bcftools filter -O z -o {output.filtered} -i 'FILTER=="high"' {output.reheader}
        """

rule annotate_roulette_w_gnomAD:
    input:
        rename=RENAME,
        gnomad=GNOMAD_DIR / 'gnomad.genomes.v4.1.sites.chr{chr_number}.vcf.bgz',
        roulette=ROULETTE_DIR/'{chr_number}_rate_v5.2_TFBS_correction_all.header.filtered.vcf'
    output:
        rename=temp(ROULETTE_DIR/'{chr_number}_rate_v5.2_TFBS_correction_all.header.filtered.rename.vcf.gz'),
        annotated=ROULETTE_DIR/'{chr_number}_rate_v5.2_TFBS_correction_all.header.filtered.rename.annotated.vcf.gz'
    threads: 1
    params:
        error_file = "stderr/vep",
        out_file = "stdout/vep",
        run_time = "6:20:00",
        cores = 1,
        memory = 80000,
    container:
        "docker://brianyee/bcftools:1.17"
    shell:
        """
        bcftools annotate --rename-chrs {input.rename} \
            {input.roulette} -Oz -o {output.rename}
        bcftools index {output.rename}
        bcftools annotate -a {input.gnomad} \
            -c INFO/AC,INFO/AN \
            -k {output.rename} \
            -o {output.annotated}
        bcftools index {output.annotated}
        """

rule fetch_SNP_from_gnomAD_and_roulette:
    ''' fetch gnomAD variants from database '''
    input:
        vcf=ROULETTE_DIR/'{chr_number}_rate_v5.2_TFBS_correction_all.header.filtered.rename.annotated.vcf.gz',
        finemapped_windows = "output/finemapping/mapped_sites/{experiment_label}.finemapped_windows.bed.gz"
    output:
        "output/variants/gnomAD_roulette/{experiment_label}.chr{chr_number}.vcf"
    threads: 2
    params:
        error_file = "stderr/fetch_snp.{experiment_label}.{chr_number}",
        out_file = "stdout/fetch_snp.{experiment_label}.{chr_number}",
        run_time = "13:20:00",
        cores = 1,
        memory = 40000,
    container:
        "docker://brianyee/bcftools:1.17"
    shell:
        """
        if [ -s {input.finemapped_windows} ]; then
            bcftools query -R {input.finemapped_windows} -f '%CHROM\t%POS\t%ID\t%REF\t%ALT\t%INFO/AC\t%INFO/AN\t%INFO/MR\t%INFO/AR\t%INFO/MG\t%INFO/MC\n' \
                {input.vcf} > {output}
        else
            touch {output}
        fi
        """

rule slop_finemap:
    input:
        finemapped_windows = "output/finemapping/mapped_sites/{experiment_label}.finemapped_windows.bed.gz"
    output:
        "output/finemapping/mapped_sites/{experiment_label}.finemapped_windows.slop.bed.gz"
    threads: 2
    params:
        error_file = "stderr/slop_finemap.{experiment_label}",
        out_file = "stdout/slop_finemap.{experiment_label}",
        run_time = "06:20:00",
        cores = 1,
        memory = 40000,
    container:
        "docker://howardxu520/skipper:bigwig_1.0"
    shell:
        """
        bedtools slop -i {input.finemapped_windows} -g {CHROM_SIZES} -b 100 | gzip -c > {output}
        """

rule fetch_peak_sequence:
    input:
        finemapped_windows = rules.slop_finemap.output,
    output:
        finemapped_fa = "output/ml/sequence/{experiment_label}.foreground.slop.fa",
    params:
        error_file = "stderr/{experiment_label}.fetch_sequence.err",
        out_file = "stdout/{experiment_label}.fetch_sequence.out",
        run_time = "40:00",
        memory = "2000",
        job_name = "run_homer",
        fa = config['GENOME']
    container:
        "docker://howardxu520/skipper:bedtools_2.31.0"
    shell:
        '''
        bedtools getfasta -fo {output.finemapped_fa} -fi {params.fa} -bed {input.finemapped_windows} -s
        '''

rule fetch_variant_sequence:
    input:
        subset_vcf="output/variants/{subset}/{experiment_label_thing}.vcf",
        seq_fa = lambda wildcards: f"output/ml/sequence/{wildcards.experiment_label_thing}.foreground.slop.fa" 
            if 'chr' not in wildcards.experiment_label_thing
            else "output/ml/sequence/"+wildcards.experiment_label_thing.split('.')[0]+".foreground.slop.fa",
        finemapped_windows = lambda wildcards: f"output/finemapping/mapped_sites/{wildcards.experiment_label_thing}.finemapped_windows.slop.bed.gz" 
            if 'chr' not in wildcards.experiment_label_thing
            else "output/finemapping/mapped_sites/"+wildcards.experiment_label_thing.split('.')[0]+".finemapped_windows.slop.bed.gz"
    output:
        ref_fa = temp("output/variants/{subset}/{experiment_label_thing}.ref.fa"),
        alt_fa = temp("output/variants/{subset}/{experiment_label_thing}.alt.fa"),
        csv = "output/variants/{subset}/{experiment_label_thing}.csv"
    threads: 2
    params:
        error_file = "stderr/fetch_sequence.{subset}.{experiment_label_thing}",
        out_file = "stdout/fetch_sequence.{subset}.{experiment_label_thing}",
        run_time = "01:20:00",
        cores = 1,
        out_prefix = lambda wildcards, output: output.csv.replace('.csv', ''),
        memory = 80000,
    conda:
        "envs/metadensity.yaml"
    shell:
        """
        if [ -s {input.subset_vcf} ]; then
            python {TOOL_DIR}/generate_variant_sequence.py \
                {input.subset_vcf} \
                {input.seq_fa} \
                {input.finemapped_windows} \
                {params.out_prefix}
        else
            touch {output.csv}
            touch {output.ref_fa}
            touch {output.alt_fa}
        fi
        """

rule score_fa:
    input:
        model=lambda wildcards: "output/ml/rbpnet_model/{experiment_label_thing}/training_done" if 'chr' not in wildcards.experiment_label_thing 
            else "output/ml/rbpnet_model/"+wildcards.experiment_label_thing.split('.')[0]+"/training_done",
        fa = "output/variants/{subset}/{experiment_label_thing}.{type}.fa"
    output:
        score=temp("output/variants/{subset}/{experiment_label_thing}.{type}.score.csv"),
        fai=temp("output/variants/{subset}/{experiment_label_thing}.{type}.fa.fai")
    threads: 1
    params:
        error_file = "stderr/score_fa.{subset}.{experiment_label_thing}",
        out_file = "stdout/score_fa.{subset}.{experiment_label_thing}",
        run_time = "00:20:00",
        cores = 1,
        memory = 80000,
        exp =lambda wildcards: wildcards.experiment_label_thing.split('.')[0],
    container:
        "/tscc/nfs/home/bay001/eugene-tools_0.1.2.sif"
    shell:
        """
        export NUMBA_CACHE_DIR=/tscc/lustre/ddn/scratch/${{USER}} # TODO: HARCODED IS BAD
        export MPLCONFIGDIR=/tscc/lustre/ddn/scratch/${{USER}}
        if [ -s {input.fa} ]; then
            python {RBPNET_PATH}/score_fa.py \
                output/ml/rbpnet_model/{params.exp}/ \
                {input.fa} \
                {output.score}
        else
            touch {output.score}
            touch {output.fai}
        fi
        """

rule join_gnomAD_info:
    input:
        scores = expand("output/variants/gnomAD_roulette/{experiment_label}.chr{chr_number}.{type}.score.csv",
            experiment_label = ["{experiment_label}"],
            chr_number = list(range(1,23)),
            type = ["ref", "alt"]),
        vcf = expand("output/variants/gnomAD_roulette/{experiment_label}.chr{chr_number}.vcf",
            experiment_label = ["{experiment_label}"],
            chr_number = list(range(1,23))),
    output:
        "output/variants/gnomAD_roulette/{experiment_label}.total.csv"
    threads: 1
    params:
        error_file = "stderr/join_gnomAD_info.{experiment_label}",
        out_file = "stdout/join_gnomAD_info.{experiment_label}",
        run_time = "00:20:00",
        cores = 1,
        memory = 80000,
    run:
        indir = Path('output/variants/gnomAD_roulette/')
        scores = []
        exp = wildcards.experiment_label
        for chr in range(1,23):
            if os.stat(indir / f'{exp}.chr{chr}.vcf').st_size == 0:
                continue
            print(f'handling chrom{chr}')
            alt_score = pd.read_csv(indir / f'{exp}.chr{chr}.alt.score.csv', index_col = 0)
            ref_score = pd.read_csv(indir / f'{exp}.chr{chr}.ref.score.csv', index_col = 0)

            
            vcf = pd.read_csv(indir / f'{exp}.chr{chr}.vcf', sep = '\t',
                            names = ['CHROM', 'POS', '.', 'REF', 'ALT',
                                    'INFO/AC', 'INFO/AN', 'INFO/MR', 'INFO/AR',
                                    'INFO/MG', 'INFO/MC'])

            ref_score[['CHROM', 'POS', 'REF', 'name']]=ref_score['ID'].str.split('-', expand = True)
            alt_score[['CHROM', 'POS', 'ALT', 'name']]=alt_score['ID'].str.split('-', expand = True)
            score = alt_score.drop('ID', axis = 1).merge(ref_score.drop('ID', axis = 1), 
                            left_on = ['CHROM', 'POS', 'name'],
                            right_on = ['CHROM', 'POS', 'name'],
                            suffixes = ('_ALT', '_REF')
                            )
            score['delta_score'] = score['dlogodds_pred_ALT']-score['dlogodds_pred_REF']
            score['POS'] = score['POS'].astype(int)
            score_m = score.merge(vcf.drop('.', axis = 1), left_on = ['CHROM', 'POS', 'REF', 'ALT'],
                        right_on = ['CHROM', 'POS', 'REF', 'ALT']
                    )
            scores.append(score_m)
        try:
            scores = pd.concat(scores, axis = 0)
            scores.to_csv(output[0], index = False)
        except:
            print('no gnomAD variants found')
            open(output[0], 'w').close()

rule fetch_Clinvar_SNP:
    input:
        finemapped_windows = "output/finemapping/mapped_sites/{experiment_label}.finemapped_windows.bed.gz",
        vcf = CLINVAR_VCF.replace('.vcf.gz', '.rename.vcf.gz')
    output:
        "output/variants/clinvar/{experiment_label}.vcf"
    threads: 2
    params:
        error_file = "stderr/fetch_clinvar_snp.{experiment_label}",
        out_file = "stdout/fetch_clinvar_snp.{experiment_label}",
        run_time = "3:20:00",
        cores = 1,
        memory = 60000,
    container:
        "docker://brianyee/bcftools:1.17"
    shell:
        """
        if [ -s {input.finemapped_windows} ]; then
            bcftools query -R {input.finemapped_windows} \
                -f '%CHROM\t%POS\t%ID\t%REF\t%ALT\t%INFO/CLNDN\t%INFO/CLNVC\t%INFO/CLNSIG\t%INFO/CLNDISDB\t%INFO/AF_ESP\t%INFO/AF_EXAC\t%INFO/AF_TGP\t%INFO/ALLELEID\n' \
                {input.vcf} > {output}
        else
            touch {output}
        fi
        """

rule vep:
    input:
        "output/variants/clinvar/{experiment_label}.vcf"
    output:
        "output/variants/clinvar/{experiment_label}.vep.tsv"
    threads: 2
    params:
        error_file = "stderr/vep",
        out_file = "stdout/vep",
        run_time = "1:20:00",
        cores = 1,
        memory = 40000,
        cache= VEP_CACHEDIR
    container:
        "docker://ensemblorg/ensembl-vep:latest"
    shell:
        """
        if [ -s {input} ]; then
            vep \
            -i {input} \
            --force_overwrite \
            -o {output} -offline --cache {params.cache}
        else
            touch {output}
        fi
        """

rule variant_analysis:
    input:
        clinvar = "output/variants/clinvar/{experiment_label}.vep.tsv",
        gnomAD = "output/variants/gnomAD_roulette/{experiment_label}.total.csv",
        annotated = "output/finemapping/mapped_sites/{experiment_label}.finemapped_windows.annotated.tsv"
    output:
        "output/variant_analysis/{experiment_label}.clinvar_variants.csv",
        "output/variant_analysis/{experiment_label}.annotated.csv.gz",
        "output/variant_analysis/{experiment_label}.feature_type_top.oe_stat.lofbins.csv",
        "output/variant_analysis/{experiment_label}.transcript_type_top.MAPS_stat.csv",
        "output/variant_analysis/{experiment_label}.feature_type_top_spectrum_enrichment.csv",
        "output/variant_analysis/{experiment_label}.transcript_type_top.MAPS.csv",
        "output/variant_analysis/{experiment_label}.feature_type_top.oe.csv",
        "output/variant_analysis/{experiment_label}.transcript_type_top_spectrum_enrichment.csv",
        "output/variant_analysis/{experiment_label}.transcript_type_top.oe_stat.csv",
        "output/variant_analysis/{experiment_label}.transcript_type_top.oe.csv",
        "output/variant_analysis/{experiment_label}.clinvar_CLINSIC_counts.csv",
        "output/variant_analysis/{experiment_label}.global_MAPS.csv",
        "output/variant_analysis/{experiment_label}.global_spectrum_enrichment.csv",
        "output/variant_analysis/{experiment_label}.feature_type_top.MAPS.lofbins.csv",
        "output/variant_analysis/{experiment_label}.feature_type_top.oe_stat.csv",
        "output/variant_analysis/{experiment_label}.clinvar_impact_counts.pdf",
        "output/variant_analysis/{experiment_label}.clinvar_CLINSIC_counts.pdf",
        "output/variant_analysis/{experiment_label}.global_MAPS_stat.csv",
        "output/variant_analysis/{experiment_label}.feature_type_top.MAPS_stat.lofbins.csv",
        "output/variant_analysis/{experiment_label}.global_oe.csv",
        "output/variant_analysis/{experiment_label}.feature_type_top.MAPS_stat.csv",
        "output/variant_analysis/{experiment_label}.clinvar_impact_counts.csv",
        "output/variant_analysis/{experiment_label}.clinvar_variants_exploded.csv",
        "output/variant_analysis/{experiment_label}.global_oe_stat.csv",
        "output/variant_analysis/{experiment_label}.feature_type_top.MAPS.csv",
        "output/variant_analysis/{experiment_label}.feature_type_top.oe.lofbins.csv",
    threads: 1
    params:
        error_file = "stderr/variant_analysis.{experiment_label}",
        out_file = "stdout/variant_analysis.{experiment_label}",
        run_time = "00:20:00",
        cores = 1,
        memory = 40000,
    conda:
        "envs/metadensity.yaml"
    shell:
        """
        if [ -s {input.gnomAD} ]; then
            python {TOOL_DIR}/mega_variant_analysis.py \
                . \
                {wildcards.experiment_label} 
        else
            touch {output}
        fi
        """

