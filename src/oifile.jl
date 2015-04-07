#
# oifile.jl --
#
# Implement reading/writing of OI-FITS data from/to FITS files.
#
#------------------------------------------------------------------------------
#
# This file is part of OIFITS.jl which is licensed under the MIT "Expat"
# License:
#
# Copyright (C) 2015, Éric Thiébaut.
#
#------------------------------------------------------------------------------

using FITSIO

# Read a column from a table.
function oifits_read_column(ff::FITSFile, colnum::Integer)
    # Make sure FITS file is open.
    fits_assert_open(ff)

    # Get the type and the dimensions of the data stored in the column.
    (typecode, repcnt, width) = fits_get_eqcoltype(ff, colnum)
    dims = fits_read_tdim(ff, colnum)
    nrows = fits_get_num_rows(ff)

    # Allocate the array and read the column contents.
    T = fits_datatype(typecode)
    if T <: String
        # Column contains an array of strings.  Strip the leading dimension
        # which is the maximum length of each strings.  On return trailing
        # spaces are removed (they are insignificant according to the FITS
        # norm).
        T = ASCIIString
        if length(dims) == 1
            dims = nrows
        else
            dims[1:end-1] = dims[2:end]
            dims[end] = nrows
        end
        data = Array(T, dims...)
        fits_read_col(ff, colnum, 1, 1, data)
        return map(rstrip, data)
    elseif T == Nothing
        error("unsupported column data")
    else
        # Column contains numerical data.
        if length(dims) == 1 && dims[1] == 1
            # Result will be a simple vector.
            dims = nrows
        else
            # Result will be a multi-dimensional array.
            push!(dims, nrows)
        end
        data = Array(T, dims...)
        fits_read_col(ff, colnum, 1, 1, data)
        return data
    end
end

# Get the type of the data-block.
function oifits_get_dbtype(hdr::FITSHeader)
    if get_hdutype(hdr) == :binary_table
        extname = fixname(oifits_get_string(hdr, "EXTNAME", ""))
        if beginswith(extname, "OI_")
            return symbol(replace(extname, r"[^A-Z0-9_]", '_'))
        end
    end
    :unknown
end

const _COMMENT = Set(["HISTORY", "COMMENT"])

function oifits_get_value(hdr::FITSHeader, key::String)
    haskey(hdr, key) || error("missing FITS keyword $key")
    hdr[key]
end

function oifits_get_value(hdr::FITSHeader, key::String, def)
    haskey(hdr, key) ? hdr[key] : def
end

function oifits_get_comment(hdr::FITSHeader, key::String)
    haskey(hdr, key) || error("missing FITS keyword $key")
    getcomment(hdr, key)
end

function oifits_get_comment(hdr::FITSHeader, key::String, def::String)
    haskey(hdr, key) ? getcomment(hdr, key) : def
end

for (fn, T, S) in ((:oifits_get_integer, Integer, Int),
                   (:oifits_get_real,    Real,    Float64),
                   (:oifits_get_logical, Bool,    Bool),
                   (:oifits_get_string,  String,  ASCIIString))
    @eval begin
        function $fn(hdr::FITSHeader, key::String, def::$T)
            val = haskey(hdr, key) ? hdr[key] : def
            isa(val, $T) || error("bad type for FITS keyword $key")
            return typeof(val) != $S ? convert($S, val) : val
        end
        function $fn(hdr::FITSHeader, key::String)
            haskey(hdr, key) || error("missing FITS keyword $key")
            val = hdr[key]
            isa(val, $T) || error("bad type for FITS keyword $key")
            return typeof(val) != $S ? convert($S, val) : val
        end
    end
end

# Returns invalid result if not a valid OI-FITS data-block.
# Unless quiet is true, print warn message.
function check_datablock(hdr::FITSHeader; quiet::Bool=false)
    # Values returned in case of error.
    dbname = ""
    dbrevn = -1
    dbdefn = nothing

    # Use a while loop to break out whenever an error occurs.
    while get_hdutype(hdr) == :binary_table
        # Get extension name.
        extname = oifits_get_value(hdr, "EXTNAME", nothing)
        if ! isa(extname, String)
            quiet || warn(extname == nothing ? "missing keyword EXTNAME"
                                             : "EXTNAME value is not a string")
            break
        end
        extname = fixname(extname)
        beginswith(extname, "OI_") || break
        dbname = extname
        if ! haskey(_DATABLOCKS, dbname)
            quiet || warn("unknown OI-FITS data-block \"$extname\"")
            break
        end

        # Get revision number.
        revn = oifits_get_value(hdr, "OI_REVN", nothing)
        if ! isa(revn, Integer)
            quiet || warn(revn == nothing ? "missing keyword OI_REVN"
                                          : "OI_REVN value is not an integer")
            break
        end
        dbrevn = revn
        if dbrevn <= 0
            quiet || warn("invalid OI_REVN value ($dbrevn)")
            break
        end
        if dbrevn > length(_FORMATS)
            quiet || warn("unsupported OI_REVN value ($dbrevn)")
            break
        end
        if ! haskey(_FORMATS[dbrevn], dbname)
            quiet || warn("unknown OI-FITS data-block \"$extname\"")
        end
        dbdefn = _FORMATS[dbrevn][dbname]
        break
    end
    return (dbname, dbrevn, dbdefn)
end

function hash_column_names(hdr::FITSHeader)
    columns = Dict{ASCIIString,Int}()
    hdutype = get_hdutype(hdr)
    if hdutype == :binary_table || hdutype == :ascii_table
        ncols = oifits_get_integer(hdr, "TFIELDS", 0)
        for k in 1:ncols
            ttype = oifits_get_string(hdr, "TTYPE$k")
            columns[fixname(ttype)] = k
        end
    end
    columns
end

function oifits_read_datablock(ff::FITSFile; quiet::Bool=false)
    oifits_read_datablock(ff, readheader(ff), quiet=quiet)
end

function oifits_read_datablock(ff::FITSFile, hdr::FITSHeader; quiet::Bool=false)
    (dbtype, revn, defn) = check_datablock(hdr, quiet=quiet)
    defn == nothing && return nothing
    columns = hash_column_names(hdr)
    nerrs = 0
    data = Dict{Symbol,Any}([:revn => revn])
    for field in defn.fields
        spec = defn.spec[field]
        name = spec.name
        if spec.keyword
            value = oifits_get_value(hdr, name, nothing)
            if value == nothing
                warn("missing keyword \"$name\" in OI-FITS $dbtype data-block")
                ++nerrs
            else
                data[field] = value
            end
        else
            colnum = get(columns, name, 0)
            if colnum < 1
                warn("missing column \"$name\" in OI-FITS $dbtype data-block")
                ++nerrs
            else
                data[field] = oifits_read_column(ff, colnum)
            end
        end
    end
    nerrs > 0 && error("bad OI-FITS $dbtype data-block")
    return build_datablock(dbtype, revn, data)
end

function oifits_load(filename::String; quiet::Bool=false, update::Bool=true)
    return oifits_load(fits_open_file(filename), quiet=quiet, update=update)
end

function oifits_load(ff::FITSFile; quiet::Bool=false, update::Bool=true)
    master = oifits_new_master()

    # Read all contents, skipping first HDU.
    for hdu in 2:fits_get_num_hdus(ff)
        fits_movabs_hdu(ff, hdu)
        db = oifits_read_datablock(ff, quiet=quiet)
        if db == nothing
            quiet || println("skipping HDU $hdu (no OI-FITS data)")
            continue
        end
        dbname = _EXTNAMES[typeof(db)]
        quiet || println("reading OI-FITS $dbname in HDU $hdu")
        oifits_attach!(master, db)
    end
    update && oifits_update(master)
    return master
end

# Local Variables:
# mode: Julia
# tab-width: 8
# indent-tabs-mode: nil
# fill-column: 79
# coding: utf-8
# ispell-local-dictionary: "american"
# End:
