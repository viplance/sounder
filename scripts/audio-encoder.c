// Built-in command-line encoder. Input is native-endian interleaved Float32 PCM.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <lame/lame.h>
#include <vorbis/vorbisenc.h>
#include <vorbis/vorbisfile.h>

static int page(FILE *out, ogg_page *p) {
    return fwrite(p->header, 1, p->header_len, out) == (size_t)p->header_len &&
           fwrite(p->body, 1, p->body_len, out) == (size_t)p->body_len;
}
static int inspect(const char *path) {
    OggVorbis_File file;
    if (ov_fopen(path, &file)) return 1;
    vorbis_info *info = ov_info(&file, -1);
    long rate = info->rate; int channels = info->channels, section;
    double sum = 0; long long frames = 0; float **samples;
    long count;
    while ((count = ov_read_float(&file, &samples, 4096, &section)) > 0) {
        for (int c = 0; c < channels; ++c) for (long i = 0; i < count; ++i) sum += samples[c][i] * samples[c][i];
        frames += count;
    }
    ov_clear(&file);
    if (count < 0 || !frames) return 1;
    printf("{\"sampleRate\":%ld,\"channels\":%d,\"frames\":%lld,\"rms\":%.9f}\n", rate, channels, frames, sqrt(sum / (frames * channels)));
    return 0;
}
int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "--inspect-ogg")) return inspect(argv[2]);
    if (argc != 7) { fprintf(stderr, "Expected format, rate, channels, input, output, quality\n"); return 1; }
    const char *kind = argv[1]; int rate = atoi(argv[2]), channels = atoi(argv[3]);
    if ((channels != 1 && channels != 2) || rate <= 0) return 1;
    FILE *in = fopen(argv[4], "rb"), *out = fopen(argv[5], "wb+");
    if (!in || !out) { if (in) fclose(in); if (out) fclose(out); perror("Audio export"); return 1; }
    float pcm[4096 * 2]; int result = 0;
    if (!strcmp(kind, "mp3")) {
        lame_t encoder = lame_init();
        if (!encoder) { result = 1; goto finish; }
        lame_set_in_samplerate(encoder, rate); lame_set_out_samplerate(encoder, rate);
        lame_set_num_channels(encoder, channels); lame_set_brate(encoder, atoi(argv[6]));
        lame_set_quality(encoder, 0); lame_set_mode(encoder, channels == 1 ? MONO : JOINT_STEREO);
        if (lame_init_params(encoder) < 0) { lame_close(encoder); result = 1; goto finish; }
        unsigned char encoded[16384]; size_t count;
        while ((count = fread(pcm, sizeof(float) * channels, 4096, in)) > 0) {
            int bytes = channels == 2 ? lame_encode_buffer_interleaved_ieee_float(encoder, pcm, (int)count, encoded, sizeof(encoded))
                                     : lame_encode_buffer_ieee_float(encoder, pcm, pcm, (int)count, encoded, sizeof(encoded));
            if (bytes < 0 || fwrite(encoded, 1, bytes, out) != (size_t)bytes) { result = 1; break; }
        }
        if (!result) {
            int bytes = lame_encode_flush(encoder, encoded, sizeof(encoded));
            if (bytes < 0 || fwrite(encoded, 1, bytes, out) != (size_t)bytes) result = 1;
            if (!result) lame_mp3_tags_fid(encoder, out);
        }
        lame_close(encoder);
    } else if (!strcmp(kind, "ogg")) {
        vorbis_info info; vorbis_info_init(&info);
        if (vorbis_encode_init_vbr(&info, channels, rate, (float)atof(argv[6])) < 0) { vorbis_info_clear(&info); result = 1; goto finish; }
        vorbis_comment comment; vorbis_comment_init(&comment); vorbis_comment_add_tag(&comment, "ENCODER", "Sounder");
        vorbis_dsp_state dsp; vorbis_block block; ogg_stream_state stream;
        vorbis_analysis_init(&dsp, &info); vorbis_block_init(&dsp, &block); ogg_stream_init(&stream, 0x534e4452);
        ogg_packet h1, h2, h3, packet; ogg_page output;
        vorbis_analysis_headerout(&dsp, &comment, &h1, &h2, &h3);
        ogg_stream_packetin(&stream, &h1); ogg_stream_packetin(&stream, &h2); ogg_stream_packetin(&stream, &h3);
        while (ogg_stream_flush(&stream, &output)) if (!page(out, &output)) result = 1;
        int eof = 0;
        while (!eof && !result) {
            size_t count = fread(pcm, sizeof(float) * channels, 4096, in);
            if (count) {
                float **buffer = vorbis_analysis_buffer(&dsp, (int)count);
                for (int c = 0; c < channels; ++c) for (size_t i = 0; i < count; ++i) buffer[c][i] = pcm[i * channels + c];
            }
            vorbis_analysis_wrote(&dsp, (int)count); eof = count == 0;
            while (vorbis_analysis_blockout(&dsp, &block) == 1) {
                vorbis_analysis(&block, NULL); vorbis_bitrate_addblock(&block);
                while (vorbis_bitrate_flushpacket(&dsp, &packet)) {
                    ogg_stream_packetin(&stream, &packet);
                    while (ogg_stream_pageout(&stream, &output)) if (!page(out, &output)) result = 1;
                }
            }
        }
        ogg_stream_clear(&stream); vorbis_block_clear(&block); vorbis_dsp_clear(&dsp); vorbis_comment_clear(&comment); vorbis_info_clear(&info);
    } else result = 1;
finish:
    if (ferror(in) || ferror(out)) result = 1;
    if (fclose(in)) result = 1;
    if (fclose(out)) result = 1;
    if (result) fprintf(stderr, "Audio encoding failed\n");
    return result;
}
