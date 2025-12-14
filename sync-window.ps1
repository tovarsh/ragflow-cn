$REG="ccr.ccs.tencentyun.com"
$NS="comintern"
$Images = Get-Content .\upstream\images.json -Raw | ConvertFrom-Json

function RepoNameOnly([string]$img){
  $ref=$img.Split('@')[0]
  if($ref.Contains(':')){ $ref=$ref.Substring(0,$ref.LastIndexOf(':')) }
  return $ref.Split('/')[-1]
}
function TagOf([string]$img){
  if($img -match ':(?<t>[^/:@]+)$'){ return $Matches.t }
  return "latest"
}

foreach($src in $Images){
  $src=[string]$src
  $repo=RepoNameOnly $src
  $tag =TagOf $src
  $dst="$REG/$NS/$repo`:$tag"

  Write-Host "[IMAGETOOLS] $src -> $dst"
  $cmd = "docker buildx imagetools create --tag $dst $src"
  Write-Host $cmd
  iex $cmd

  if($LASTEXITCODE -ne 0){
    Write-Host "[FALLBACK docker] $src -> $dst"
    docker pull $src
    docker tag  $src $dst
    docker push $dst
  }
}
